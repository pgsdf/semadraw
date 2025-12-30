const std = @import("std");
const backend = @import("backend");

const c = @cImport({
    @cDefine("VK_USE_PLATFORM_XLIB_KHR", "1");
    @cInclude("vulkan/vulkan.h");
    @cInclude("X11/Xlib.h");
    @cInclude("X11/keysym.h");
});

// X11 Atom type alias
const Atom = c.Atom;

const log = std.log.scoped(.vulkan_backend);

/// Vulkan backend for GPU-accelerated SDCS rendering
pub const VulkanBackend = struct {
    allocator: std.mem.Allocator,

    // Vulkan core handles
    instance: c.VkInstance,
    physical_device: c.VkPhysicalDevice,
    device: c.VkDevice,
    graphics_queue: c.VkQueue,
    present_queue: c.VkQueue,
    graphics_family: u32,
    present_family: u32,

    // Surface and swapchain (for windowed presentation)
    surface: c.VkSurfaceKHR,
    swapchain: c.VkSwapchainKHR,
    swapchain_images: []c.VkImage,
    swapchain_image_views: []c.VkImageView,
    swapchain_format: c.VkFormat,
    swapchain_extent: c.VkExtent2D,

    // Render pass and framebuffers
    render_pass: c.VkRenderPass,
    framebuffers: []c.VkFramebuffer,

    // Command pool and buffers
    command_pool: c.VkCommandPool,
    command_buffers: []c.VkCommandBuffer,

    // Synchronization
    image_available_semaphore: c.VkSemaphore,
    render_finished_semaphore: c.VkSemaphore,
    in_flight_fence: c.VkFence,

    // Pipeline for 2D rendering
    pipeline_layout: c.VkPipelineLayout,
    graphics_pipeline: c.VkPipeline,

    // Vertex buffer for dynamic geometry
    vertex_buffer: c.VkBuffer,
    vertex_buffer_memory: c.VkDeviceMemory,

    // X11 window (for presentation)
    display: ?*c.Display,
    window: c.Window,
    owns_window: bool,

    // State
    width: u32,
    height: u32,
    frame_count: u64,
    closed: bool,

    // CPU-side framebuffer for readback (getPixels)
    cpu_framebuffer: ?[]u8,

    // Keyboard event queue
    key_events: [backend.MAX_KEY_EVENTS]backend.KeyEvent,
    key_event_count: usize,

    // Mouse event queue
    mouse_events: [backend.MAX_MOUSE_EVENTS]backend.MouseEvent,
    mouse_event_count: usize,

    // Modifier state tracking
    modifier_state: u8,

    // Clipboard support (X11 selections)
    atom_clipboard: Atom,
    atom_primary: Atom,
    atom_targets: Atom,
    atom_utf8_string: Atom,
    atom_string: Atom,
    atom_atom: Atom,
    clipboard_data: ?[]u8,
    primary_data: ?[]u8,
    clipboard_request_pending: bool,
    clipboard_request_selection: u8,

    const Self = @This();

    // Maximum vertices for dynamic geometry
    const MAX_VERTICES = 65536;

    // Vertex structure for 2D rendering
    const Vertex = extern struct {
        pos: [2]f32,
        color: [4]f32,
    };

    pub fn init(allocator: std.mem.Allocator) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        self.* = Self{
            .allocator = allocator,
            .instance = null,
            .physical_device = null,
            .device = null,
            .graphics_queue = null,
            .present_queue = null,
            .graphics_family = 0,
            .present_family = 0,
            .surface = null,
            .swapchain = null,
            .swapchain_images = &.{},
            .swapchain_image_views = &.{},
            .swapchain_format = c.VK_FORMAT_B8G8R8A8_SRGB,
            .swapchain_extent = .{ .width = 0, .height = 0 },
            .render_pass = null,
            .framebuffers = &.{},
            .command_pool = null,
            .command_buffers = &.{},
            .image_available_semaphore = null,
            .render_finished_semaphore = null,
            .in_flight_fence = null,
            .pipeline_layout = null,
            .graphics_pipeline = null,
            .vertex_buffer = null,
            .vertex_buffer_memory = null,
            .display = null,
            .window = 0,
            .owns_window = false,
            .width = 0,
            .height = 0,
            .frame_count = 0,
            .closed = false,
            .cpu_framebuffer = null,
            // Input event queues
            .key_events = undefined,
            .key_event_count = 0,
            .mouse_events = undefined,
            .mouse_event_count = 0,
            .modifier_state = 0,
            // Clipboard atoms (initialized after display open)
            .atom_clipboard = 0,
            .atom_primary = 0,
            .atom_targets = 0,
            .atom_utf8_string = 0,
            .atom_string = 0,
            .atom_atom = 0,
            .clipboard_data = null,
            .primary_data = null,
            .clipboard_request_pending = false,
            .clipboard_request_selection = 0,
        };

        // Create Vulkan instance
        try self.createInstance();
        errdefer self.destroyInstance();

        // Create X11 window for presentation
        try self.createWindow(1920, 1080);
        errdefer self.destroyWindow();

        // Create surface
        try self.createSurface();
        errdefer self.destroySurface();

        // Select physical device
        try self.pickPhysicalDevice();

        // Create logical device
        try self.createLogicalDevice();
        errdefer self.destroyLogicalDevice();

        // Create swapchain
        try self.createSwapchain();
        errdefer self.destroySwapchain();

        // Create render pass
        try self.createRenderPass();
        errdefer self.destroyRenderPass();

        // Create framebuffers
        try self.createFramebuffers();
        errdefer self.destroyFramebuffers();

        // Create command pool
        try self.createCommandPool();
        errdefer self.destroyCommandPool();

        // Create command buffers
        try self.createCommandBuffers();

        // Create sync objects
        try self.createSyncObjects();
        errdefer self.destroySyncObjects();

        // Create vertex buffer
        try self.createVertexBuffer();
        errdefer self.destroyVertexBuffer();

        // Create graphics pipeline
        try self.createGraphicsPipeline();

        log.info("Vulkan backend initialized: {}x{}", .{ self.width, self.height });

        return self;
    }

    pub fn deinit(self: *Self) void {
        // Wait for device to be idle before cleanup
        if (self.device != null) {
            _ = c.vkDeviceWaitIdle(self.device);
        }

        self.destroyGraphicsPipeline();
        self.destroyVertexBuffer();
        self.destroySyncObjects();
        self.destroyCommandPool();
        self.destroyFramebuffers();
        self.destroyRenderPass();
        self.destroySwapchain();
        self.destroyLogicalDevice();
        self.destroySurface();
        self.destroyWindow();
        self.destroyInstance();

        if (self.cpu_framebuffer) |fb| {
            self.allocator.free(fb);
        }

        // Free clipboard data
        if (self.clipboard_data) |data| {
            self.allocator.free(data);
        }
        if (self.primary_data) |data| {
            self.allocator.free(data);
        }

        self.allocator.destroy(self);
    }

    // ========================================================================
    // Vulkan initialization
    // ========================================================================

    fn createInstance(self: *Self) !void {
        const app_info = c.VkApplicationInfo{
            .sType = c.VK_STRUCTURE_TYPE_APPLICATION_INFO,
            .pNext = null,
            .pApplicationName = "SemaDraw",
            .applicationVersion = c.VK_MAKE_VERSION(0, 1, 0),
            .pEngineName = "SemaDraw",
            .engineVersion = c.VK_MAKE_VERSION(0, 1, 0),
            .apiVersion = c.VK_API_VERSION_1_0,
        };

        // Required extensions for X11 presentation
        const extensions = [_][*:0]const u8{
            c.VK_KHR_SURFACE_EXTENSION_NAME,
            c.VK_KHR_XLIB_SURFACE_EXTENSION_NAME,
        };

        const create_info = c.VkInstanceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .pApplicationInfo = &app_info,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = extensions.len,
            .ppEnabledExtensionNames = &extensions,
        };

        const result = c.vkCreateInstance(&create_info, null, &self.instance);
        if (result != c.VK_SUCCESS) {
            log.err("failed to create Vulkan instance: {}", .{result});
            return error.VulkanInstanceCreationFailed;
        }
    }

    fn destroyInstance(self: *Self) void {
        if (self.instance != null) {
            c.vkDestroyInstance(self.instance, null);
            self.instance = null;
        }
    }

    fn createWindow(self: *Self, width: u32, height: u32) !void {
        self.display = c.XOpenDisplay(null);
        if (self.display == null) {
            return error.X11ConnectionFailed;
        }

        const screen = c.DefaultScreen(self.display);
        const root = c.RootWindow(self.display, screen);

        self.window = c.XCreateSimpleWindow(
            self.display,
            root,
            0,
            0,
            width,
            height,
            0,
            c.BlackPixel(self.display, screen),
            c.BlackPixel(self.display, screen),
        );

        _ = c.XStoreName(self.display, self.window, "SemaDraw (Vulkan)");
        _ = c.XMapWindow(self.display, self.window);
        _ = c.XFlush(self.display);

        self.width = width;
        self.height = height;
        self.owns_window = true;

        // Initialize clipboard atoms
        self.atom_clipboard = c.XInternAtom(self.display, "CLIPBOARD", c.False);
        self.atom_primary = c.XInternAtom(self.display, "PRIMARY", c.False);
        self.atom_targets = c.XInternAtom(self.display, "TARGETS", c.False);
        self.atom_utf8_string = c.XInternAtom(self.display, "UTF8_STRING", c.False);
        self.atom_string = c.XInternAtom(self.display, "STRING", c.False);
        self.atom_atom = c.XInternAtom(self.display, "ATOM", c.False);

        // Select input events (keyboard, mouse, and window events)
        _ = c.XSelectInput(self.display, self.window, c.ExposureMask | c.KeyPressMask | c.KeyReleaseMask | c.StructureNotifyMask | c.ButtonPressMask | c.ButtonReleaseMask | c.PointerMotionMask);
    }

    fn destroyWindow(self: *Self) void {
        if (self.owns_window and self.window != 0) {
            _ = c.XDestroyWindow(self.display, self.window);
            self.window = 0;
        }
        if (self.display != null) {
            _ = c.XCloseDisplay(self.display);
            self.display = null;
        }
    }

    fn createSurface(self: *Self) !void {
        const create_info = c.VkXlibSurfaceCreateInfoKHR{
            .sType = c.VK_STRUCTURE_TYPE_XLIB_SURFACE_CREATE_INFO_KHR,
            .pNext = null,
            .flags = 0,
            .dpy = self.display,
            .window = self.window,
        };

        const result = c.vkCreateXlibSurfaceKHR(self.instance, &create_info, null, &self.surface);
        if (result != c.VK_SUCCESS) {
            log.err("failed to create Vulkan surface: {}", .{result});
            return error.VulkanSurfaceCreationFailed;
        }
    }

    fn destroySurface(self: *Self) void {
        if (self.surface != null) {
            c.vkDestroySurfaceKHR(self.instance, self.surface, null);
            self.surface = null;
        }
    }

    fn pickPhysicalDevice(self: *Self) !void {
        var device_count: u32 = 0;
        _ = c.vkEnumeratePhysicalDevices(self.instance, &device_count, null);

        if (device_count == 0) {
            log.err("no Vulkan-capable GPU found", .{});
            return error.NoVulkanDevice;
        }

        const devices = try self.allocator.alloc(c.VkPhysicalDevice, device_count);
        defer self.allocator.free(devices);

        _ = c.vkEnumeratePhysicalDevices(self.instance, &device_count, devices.ptr);

        // Find a suitable device
        for (devices) |device| {
            if (try self.isDeviceSuitable(device)) {
                self.physical_device = device;

                var props: c.VkPhysicalDeviceProperties = undefined;
                c.vkGetPhysicalDeviceProperties(device, &props);
                const device_name = std.mem.sliceTo(&props.deviceName, 0);
                log.info("selected GPU: {s}", .{device_name});

                return;
            }
        }

        log.err("no suitable GPU found", .{});
        return error.NoSuitableDevice;
    }

    fn isDeviceSuitable(self: *Self, device: c.VkPhysicalDevice) !bool {
        // Check queue families
        var queue_family_count: u32 = 0;
        c.vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, null);

        const queue_families = try self.allocator.alloc(c.VkQueueFamilyProperties, queue_family_count);
        defer self.allocator.free(queue_families);
        c.vkGetPhysicalDeviceQueueFamilyProperties(device, &queue_family_count, queue_families.ptr);

        var graphics_family: ?u32 = null;
        var present_family: ?u32 = null;

        for (queue_families, 0..) |qf, i| {
            if (qf.queueFlags & c.VK_QUEUE_GRAPHICS_BIT != 0) {
                graphics_family = @intCast(i);
            }

            var present_support: c.VkBool32 = c.VK_FALSE;
            _ = c.vkGetPhysicalDeviceSurfaceSupportKHR(device, @intCast(i), self.surface, &present_support);
            if (present_support == c.VK_TRUE) {
                present_family = @intCast(i);
            }

            if (graphics_family != null and present_family != null) break;
        }

        if (graphics_family == null or present_family == null) {
            return false;
        }

        self.graphics_family = graphics_family.?;
        self.present_family = present_family.?;

        // Check swapchain support
        var extension_count: u32 = 0;
        _ = c.vkEnumerateDeviceExtensionProperties(device, null, &extension_count, null);

        const extensions = try self.allocator.alloc(c.VkExtensionProperties, extension_count);
        defer self.allocator.free(extensions);
        _ = c.vkEnumerateDeviceExtensionProperties(device, null, &extension_count, extensions.ptr);

        var has_swapchain = false;
        for (extensions) |ext| {
            if (std.mem.eql(u8, std.mem.sliceTo(&ext.extensionName, 0), c.VK_KHR_SWAPCHAIN_EXTENSION_NAME)) {
                has_swapchain = true;
                break;
            }
        }

        return has_swapchain;
    }

    fn createLogicalDevice(self: *Self) !void {
        const queue_priority: f32 = 1.0;

        // Create queue create infos
        var queue_create_infos: [2]c.VkDeviceQueueCreateInfo = undefined;
        var queue_count: u32 = 1;

        queue_create_infos[0] = c.VkDeviceQueueCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueFamilyIndex = self.graphics_family,
            .queueCount = 1,
            .pQueuePriorities = &queue_priority,
        };

        if (self.graphics_family != self.present_family) {
            queue_create_infos[1] = c.VkDeviceQueueCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .queueFamilyIndex = self.present_family,
                .queueCount = 1,
                .pQueuePriorities = &queue_priority,
            };
            queue_count = 2;
        }

        const device_extensions = [_][*:0]const u8{
            c.VK_KHR_SWAPCHAIN_EXTENSION_NAME,
        };

        const device_features: c.VkPhysicalDeviceFeatures = std.mem.zeroes(c.VkPhysicalDeviceFeatures);

        const create_info = c.VkDeviceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .queueCreateInfoCount = queue_count,
            .pQueueCreateInfos = &queue_create_infos,
            .enabledLayerCount = 0,
            .ppEnabledLayerNames = null,
            .enabledExtensionCount = device_extensions.len,
            .ppEnabledExtensionNames = &device_extensions,
            .pEnabledFeatures = &device_features,
        };

        const result = c.vkCreateDevice(self.physical_device, &create_info, null, &self.device);
        if (result != c.VK_SUCCESS) {
            log.err("failed to create logical device: {}", .{result});
            return error.VulkanDeviceCreationFailed;
        }

        c.vkGetDeviceQueue(self.device, self.graphics_family, 0, &self.graphics_queue);
        c.vkGetDeviceQueue(self.device, self.present_family, 0, &self.present_queue);
    }

    fn destroyLogicalDevice(self: *Self) void {
        if (self.device != null) {
            c.vkDestroyDevice(self.device, null);
            self.device = null;
        }
    }

    fn createSwapchain(self: *Self) !void {
        // Query surface capabilities
        var capabilities: c.VkSurfaceCapabilitiesKHR = undefined;
        _ = c.vkGetPhysicalDeviceSurfaceCapabilitiesKHR(self.physical_device, self.surface, &capabilities);

        // Choose surface format
        var format_count: u32 = 0;
        _ = c.vkGetPhysicalDeviceSurfaceFormatsKHR(self.physical_device, self.surface, &format_count, null);

        const formats = try self.allocator.alloc(c.VkSurfaceFormatKHR, format_count);
        defer self.allocator.free(formats);
        _ = c.vkGetPhysicalDeviceSurfaceFormatsKHR(self.physical_device, self.surface, &format_count, formats.ptr);

        var surface_format = formats[0];
        for (formats) |fmt| {
            if (fmt.format == c.VK_FORMAT_B8G8R8A8_SRGB and fmt.colorSpace == c.VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
                surface_format = fmt;
                break;
            }
        }

        // Choose present mode (prefer mailbox for low latency)
        var present_mode_count: u32 = 0;
        _ = c.vkGetPhysicalDeviceSurfacePresentModesKHR(self.physical_device, self.surface, &present_mode_count, null);

        const present_modes = try self.allocator.alloc(c.VkPresentModeKHR, present_mode_count);
        defer self.allocator.free(present_modes);
        _ = c.vkGetPhysicalDeviceSurfacePresentModesKHR(self.physical_device, self.surface, &present_mode_count, present_modes.ptr);

        var present_mode: c.VkPresentModeKHR = c.VK_PRESENT_MODE_FIFO_KHR;
        for (present_modes) |mode| {
            if (mode == c.VK_PRESENT_MODE_MAILBOX_KHR) {
                present_mode = mode;
                break;
            }
        }

        // Choose extent
        var extent = capabilities.currentExtent;
        if (extent.width == 0xFFFFFFFF) {
            extent.width = std.math.clamp(self.width, capabilities.minImageExtent.width, capabilities.maxImageExtent.width);
            extent.height = std.math.clamp(self.height, capabilities.minImageExtent.height, capabilities.maxImageExtent.height);
        }

        var image_count = capabilities.minImageCount + 1;
        if (capabilities.maxImageCount > 0 and image_count > capabilities.maxImageCount) {
            image_count = capabilities.maxImageCount;
        }

        var create_info = c.VkSwapchainCreateInfoKHR{
            .sType = c.VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR,
            .pNext = null,
            .flags = 0,
            .surface = self.surface,
            .minImageCount = image_count,
            .imageFormat = surface_format.format,
            .imageColorSpace = surface_format.colorSpace,
            .imageExtent = extent,
            .imageArrayLayers = 1,
            .imageUsage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT,
            .imageSharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
            .preTransform = capabilities.currentTransform,
            .compositeAlpha = c.VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR,
            .presentMode = present_mode,
            .clipped = c.VK_TRUE,
            .oldSwapchain = null,
        };

        const queue_family_indices = [_]u32{ self.graphics_family, self.present_family };
        if (self.graphics_family != self.present_family) {
            create_info.imageSharingMode = c.VK_SHARING_MODE_CONCURRENT;
            create_info.queueFamilyIndexCount = 2;
            create_info.pQueueFamilyIndices = &queue_family_indices;
        }

        const result = c.vkCreateSwapchainKHR(self.device, &create_info, null, &self.swapchain);
        if (result != c.VK_SUCCESS) {
            log.err("failed to create swapchain: {}", .{result});
            return error.SwapchainCreationFailed;
        }

        self.swapchain_format = surface_format.format;
        self.swapchain_extent = extent;
        self.width = extent.width;
        self.height = extent.height;

        // Get swapchain images
        var actual_image_count: u32 = 0;
        _ = c.vkGetSwapchainImagesKHR(self.device, self.swapchain, &actual_image_count, null);

        self.swapchain_images = try self.allocator.alloc(c.VkImage, actual_image_count);
        _ = c.vkGetSwapchainImagesKHR(self.device, self.swapchain, &actual_image_count, self.swapchain_images.ptr);

        // Create image views
        self.swapchain_image_views = try self.allocator.alloc(c.VkImageView, actual_image_count);

        for (self.swapchain_images, 0..) |image, i| {
            const view_info = c.VkImageViewCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .image = image,
                .viewType = c.VK_IMAGE_VIEW_TYPE_2D,
                .format = self.swapchain_format,
                .components = .{
                    .r = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                    .g = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                    .b = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                    .a = c.VK_COMPONENT_SWIZZLE_IDENTITY,
                },
                .subresourceRange = .{
                    .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
                    .baseMipLevel = 0,
                    .levelCount = 1,
                    .baseArrayLayer = 0,
                    .layerCount = 1,
                },
            };

            const view_result = c.vkCreateImageView(self.device, &view_info, null, &self.swapchain_image_views[i]);
            if (view_result != c.VK_SUCCESS) {
                return error.ImageViewCreationFailed;
            }
        }
    }

    fn destroySwapchain(self: *Self) void {
        for (self.swapchain_image_views) |view| {
            c.vkDestroyImageView(self.device, view, null);
        }
        if (self.swapchain_image_views.len > 0) {
            self.allocator.free(self.swapchain_image_views);
            self.swapchain_image_views = &.{};
        }

        if (self.swapchain_images.len > 0) {
            self.allocator.free(self.swapchain_images);
            self.swapchain_images = &.{};
        }

        if (self.swapchain != null) {
            c.vkDestroySwapchainKHR(self.device, self.swapchain, null);
            self.swapchain = null;
        }
    }

    fn createRenderPass(self: *Self) !void {
        const color_attachment = c.VkAttachmentDescription{
            .flags = 0,
            .format = self.swapchain_format,
            .samples = c.VK_SAMPLE_COUNT_1_BIT,
            .loadOp = c.VK_ATTACHMENT_LOAD_OP_CLEAR,
            .storeOp = c.VK_ATTACHMENT_STORE_OP_STORE,
            .stencilLoadOp = c.VK_ATTACHMENT_LOAD_OP_DONT_CARE,
            .stencilStoreOp = c.VK_ATTACHMENT_STORE_OP_DONT_CARE,
            .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
            .finalLayout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR,
        };

        const color_attachment_ref = c.VkAttachmentReference{
            .attachment = 0,
            .layout = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,
        };

        const subpass = c.VkSubpassDescription{
            .flags = 0,
            .pipelineBindPoint = c.VK_PIPELINE_BIND_POINT_GRAPHICS,
            .inputAttachmentCount = 0,
            .pInputAttachments = null,
            .colorAttachmentCount = 1,
            .pColorAttachments = &color_attachment_ref,
            .pResolveAttachments = null,
            .pDepthStencilAttachment = null,
            .preserveAttachmentCount = 0,
            .pPreserveAttachments = null,
        };

        const dependency = c.VkSubpassDependency{
            .srcSubpass = c.VK_SUBPASS_EXTERNAL,
            .dstSubpass = 0,
            .srcStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .dstStageMask = c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT,
            .srcAccessMask = 0,
            .dstAccessMask = c.VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT,
            .dependencyFlags = 0,
        };

        const render_pass_info = c.VkRenderPassCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .attachmentCount = 1,
            .pAttachments = &color_attachment,
            .subpassCount = 1,
            .pSubpasses = &subpass,
            .dependencyCount = 1,
            .pDependencies = &dependency,
        };

        const result = c.vkCreateRenderPass(self.device, &render_pass_info, null, &self.render_pass);
        if (result != c.VK_SUCCESS) {
            return error.RenderPassCreationFailed;
        }
    }

    fn destroyRenderPass(self: *Self) void {
        if (self.render_pass != null) {
            c.vkDestroyRenderPass(self.device, self.render_pass, null);
            self.render_pass = null;
        }
    }

    fn createFramebuffers(self: *Self) !void {
        self.framebuffers = try self.allocator.alloc(c.VkFramebuffer, self.swapchain_image_views.len);

        for (self.swapchain_image_views, 0..) |view, i| {
            const attachments = [_]c.VkImageView{view};

            const framebuffer_info = c.VkFramebufferCreateInfo{
                .sType = c.VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO,
                .pNext = null,
                .flags = 0,
                .renderPass = self.render_pass,
                .attachmentCount = 1,
                .pAttachments = &attachments,
                .width = self.swapchain_extent.width,
                .height = self.swapchain_extent.height,
                .layers = 1,
            };

            const result = c.vkCreateFramebuffer(self.device, &framebuffer_info, null, &self.framebuffers[i]);
            if (result != c.VK_SUCCESS) {
                return error.FramebufferCreationFailed;
            }
        }
    }

    fn destroyFramebuffers(self: *Self) void {
        for (self.framebuffers) |fb| {
            c.vkDestroyFramebuffer(self.device, fb, null);
        }
        if (self.framebuffers.len > 0) {
            self.allocator.free(self.framebuffers);
            self.framebuffers = &.{};
        }
    }

    fn createCommandPool(self: *Self) !void {
        const pool_info = c.VkCommandPoolCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
            .pNext = null,
            .flags = c.VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT,
            .queueFamilyIndex = self.graphics_family,
        };

        const result = c.vkCreateCommandPool(self.device, &pool_info, null, &self.command_pool);
        if (result != c.VK_SUCCESS) {
            return error.CommandPoolCreationFailed;
        }
    }

    fn destroyCommandPool(self: *Self) void {
        // Free command buffers allocation
        if (self.command_buffers.len > 0) {
            self.allocator.free(self.command_buffers);
            self.command_buffers = &.{};
        }

        if (self.command_pool != null) {
            c.vkDestroyCommandPool(self.device, self.command_pool, null);
            self.command_pool = null;
        }
    }

    fn createCommandBuffers(self: *Self) !void {
        self.command_buffers = try self.allocator.alloc(c.VkCommandBuffer, self.swapchain_images.len);

        const alloc_info = c.VkCommandBufferAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
            .pNext = null,
            .commandPool = self.command_pool,
            .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
            .commandBufferCount = @intCast(self.command_buffers.len),
        };

        const result = c.vkAllocateCommandBuffers(self.device, &alloc_info, self.command_buffers.ptr);
        if (result != c.VK_SUCCESS) {
            return error.CommandBufferAllocationFailed;
        }
    }

    fn createSyncObjects(self: *Self) !void {
        const semaphore_info = c.VkSemaphoreCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO,
            .pNext = null,
            .flags = 0,
        };

        const fence_info = c.VkFenceCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
            .pNext = null,
            .flags = c.VK_FENCE_CREATE_SIGNALED_BIT,
        };

        if (c.vkCreateSemaphore(self.device, &semaphore_info, null, &self.image_available_semaphore) != c.VK_SUCCESS or
            c.vkCreateSemaphore(self.device, &semaphore_info, null, &self.render_finished_semaphore) != c.VK_SUCCESS or
            c.vkCreateFence(self.device, &fence_info, null, &self.in_flight_fence) != c.VK_SUCCESS)
        {
            return error.SyncObjectCreationFailed;
        }
    }

    fn destroySyncObjects(self: *Self) void {
        if (self.in_flight_fence != null) {
            c.vkDestroyFence(self.device, self.in_flight_fence, null);
        }
        if (self.render_finished_semaphore != null) {
            c.vkDestroySemaphore(self.device, self.render_finished_semaphore, null);
        }
        if (self.image_available_semaphore != null) {
            c.vkDestroySemaphore(self.device, self.image_available_semaphore, null);
        }
    }

    fn createVertexBuffer(self: *Self) !void {
        const buffer_size = MAX_VERTICES * @sizeOf(Vertex);

        const buffer_info = c.VkBufferCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .size = buffer_size,
            .usage = c.VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .queueFamilyIndexCount = 0,
            .pQueueFamilyIndices = null,
        };

        if (c.vkCreateBuffer(self.device, &buffer_info, null, &self.vertex_buffer) != c.VK_SUCCESS) {
            return error.BufferCreationFailed;
        }

        var mem_requirements: c.VkMemoryRequirements = undefined;
        c.vkGetBufferMemoryRequirements(self.device, self.vertex_buffer, &mem_requirements);

        const memory_type = try self.findMemoryType(
            mem_requirements.memoryTypeBits,
            c.VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | c.VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
        );

        const alloc_info = c.VkMemoryAllocateInfo{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = null,
            .allocationSize = mem_requirements.size,
            .memoryTypeIndex = memory_type,
        };

        if (c.vkAllocateMemory(self.device, &alloc_info, null, &self.vertex_buffer_memory) != c.VK_SUCCESS) {
            return error.MemoryAllocationFailed;
        }

        _ = c.vkBindBufferMemory(self.device, self.vertex_buffer, self.vertex_buffer_memory, 0);
    }

    fn destroyVertexBuffer(self: *Self) void {
        if (self.vertex_buffer != null) {
            c.vkDestroyBuffer(self.device, self.vertex_buffer, null);
        }
        if (self.vertex_buffer_memory != null) {
            c.vkFreeMemory(self.device, self.vertex_buffer_memory, null);
        }
    }

    fn findMemoryType(self: *Self, type_filter: u32, properties: c.VkMemoryPropertyFlags) !u32 {
        var mem_properties: c.VkPhysicalDeviceMemoryProperties = undefined;
        c.vkGetPhysicalDeviceMemoryProperties(self.physical_device, &mem_properties);

        for (0..mem_properties.memoryTypeCount) |i| {
            if ((type_filter & (@as(u32, 1) << @intCast(i))) != 0 and
                (mem_properties.memoryTypes[i].propertyFlags & properties) == properties)
            {
                return @intCast(i);
            }
        }

        return error.NoSuitableMemoryType;
    }

    fn createGraphicsPipeline(self: *Self) !void {
        // For now, create a simple pipeline without shaders
        // In a full implementation, we'd compile SPIR-V shaders for 2D rendering

        // Create pipeline layout (empty for now)
        const pipeline_layout_info = c.VkPipelineLayoutCreateInfo{
            .sType = c.VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO,
            .pNext = null,
            .flags = 0,
            .setLayoutCount = 0,
            .pSetLayouts = null,
            .pushConstantRangeCount = 0,
            .pPushConstantRanges = null,
        };

        if (c.vkCreatePipelineLayout(self.device, &pipeline_layout_info, null, &self.pipeline_layout) != c.VK_SUCCESS) {
            return error.PipelineLayoutCreationFailed;
        }

        // Note: Full graphics pipeline creation requires SPIR-V shaders
        // For initial implementation, we'll use vkCmdClearColorImage for basic rendering
        self.graphics_pipeline = null;
    }

    fn destroyGraphicsPipeline(self: *Self) void {
        if (self.graphics_pipeline != null) {
            c.vkDestroyPipeline(self.device, self.graphics_pipeline, null);
        }
        if (self.pipeline_layout != null) {
            c.vkDestroyPipelineLayout(self.device, self.pipeline_layout, null);
        }
    }

    // ========================================================================
    // Backend interface implementation
    // ========================================================================

    fn getCapabilitiesImpl(ctx: *anyopaque) backend.Capabilities {
        const self: *Self = @ptrCast(@alignCast(ctx));
        _ = self;
        return .{
            .name = "vulkan",
            .max_width = 16384,
            .max_height = 16384,
            .supports_aa = true,
            .hardware_accelerated = true,
            .can_present = true,
        };
    }

    fn initFramebufferImpl(ctx: *anyopaque, config: backend.FramebufferConfig) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));

        // Allocate CPU framebuffer for getPixels
        if (self.cpu_framebuffer) |fb| {
            self.allocator.free(fb);
        }

        const size = @as(usize, config.width) * @as(usize, config.height) * 4;
        self.cpu_framebuffer = try self.allocator.alloc(u8, size);
        @memset(self.cpu_framebuffer.?, 0);

        // Resize window if needed
        if (config.width != self.width or config.height != self.height) {
            // Would need to recreate swapchain
            log.info("framebuffer config: {}x{} (swapchain: {}x{})", .{
                config.width,
                config.height,
                self.width,
                self.height,
            });
        }
    }

    fn renderImpl(ctx: *anyopaque, request: backend.RenderRequest) anyerror!backend.RenderResult {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const start_time = std.time.nanoTimestamp();

        // Process X11 events
        if (!self.processEvents()) {
            return backend.RenderResult.failure(request.surface_id, "window closed");
        }

        // Wait for previous frame
        _ = c.vkWaitForFences(self.device, 1, &self.in_flight_fence, c.VK_TRUE, std.math.maxInt(u64));
        _ = c.vkResetFences(self.device, 1, &self.in_flight_fence);

        // Acquire next image
        var image_index: u32 = 0;
        const acquire_result = c.vkAcquireNextImageKHR(
            self.device,
            self.swapchain,
            std.math.maxInt(u64),
            self.image_available_semaphore,
            null,
            &image_index,
        );

        if (acquire_result == c.VK_ERROR_OUT_OF_DATE_KHR) {
            // Would need to recreate swapchain
            return backend.RenderResult.failure(request.surface_id, "swapchain out of date");
        }

        // Record command buffer
        const cmd = self.command_buffers[image_index];
        _ = c.vkResetCommandBuffer(cmd, 0);

        const begin_info = c.VkCommandBufferBeginInfo{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .pNext = null,
            .flags = 0,
            .pInheritanceInfo = null,
        };
        _ = c.vkBeginCommandBuffer(cmd, &begin_info);

        // Begin render pass
        var clear_value: c.VkClearValue = undefined;
        if (request.clear_color) |color| {
            clear_value.color.float32 = color;
        } else {
            clear_value.color.float32 = .{ 0.0, 0.0, 0.0, 1.0 };
        }

        const render_pass_info = c.VkRenderPassBeginInfo{
            .sType = c.VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO,
            .pNext = null,
            .renderPass = self.render_pass,
            .framebuffer = self.framebuffers[image_index],
            .renderArea = .{
                .offset = .{ .x = 0, .y = 0 },
                .extent = self.swapchain_extent,
            },
            .clearValueCount = 1,
            .pClearValues = &clear_value,
        };

        c.vkCmdBeginRenderPass(cmd, &render_pass_info, c.VK_SUBPASS_CONTENTS_INLINE);

        // TODO: Parse SDCS commands and render geometry
        // For now, just clear the screen
        _ = request.sdcs_data;

        c.vkCmdEndRenderPass(cmd);
        _ = c.vkEndCommandBuffer(cmd);

        // Submit
        const wait_stages = [_]c.VkPipelineStageFlags{c.VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT};
        const submit_info = c.VkSubmitInfo{
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO,
            .pNext = null,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &[_]c.VkSemaphore{self.image_available_semaphore},
            .pWaitDstStageMask = &wait_stages,
            .commandBufferCount = 1,
            .pCommandBuffers = &[_]c.VkCommandBuffer{cmd},
            .signalSemaphoreCount = 1,
            .pSignalSemaphores = &[_]c.VkSemaphore{self.render_finished_semaphore},
        };

        _ = c.vkQueueSubmit(self.graphics_queue, 1, &submit_info, self.in_flight_fence);

        // Present
        const present_info = c.VkPresentInfoKHR{
            .sType = c.VK_STRUCTURE_TYPE_PRESENT_INFO_KHR,
            .pNext = null,
            .waitSemaphoreCount = 1,
            .pWaitSemaphores = &[_]c.VkSemaphore{self.render_finished_semaphore},
            .swapchainCount = 1,
            .pSwapchains = &[_]c.VkSwapchainKHR{self.swapchain},
            .pImageIndices = &[_]u32{image_index},
            .pResults = null,
        };

        _ = c.vkQueuePresentKHR(self.present_queue, &present_info);

        self.frame_count += 1;
        const end_time = std.time.nanoTimestamp();

        return backend.RenderResult.success(
            request.surface_id,
            self.frame_count,
            @intCast(end_time - start_time),
        );
    }

    fn getPixelsImpl(ctx: *anyopaque) ?[]u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.cpu_framebuffer;
    }

    fn resizeImpl(ctx: *anyopaque, width: u32, height: u32) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        _ = width;
        _ = height;
        // Would need to recreate swapchain
        log.warn("resize not fully implemented for Vulkan backend", .{});
        _ = self;
    }

    fn pollEventsImpl(ctx: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.processEvents();
    }

    fn deinitImpl(ctx: *anyopaque) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    fn processEvents(self: *Self) bool {
        if (self.display == null) return !self.closed;

        // Clear event queues for this poll cycle
        self.key_event_count = 0;
        self.mouse_event_count = 0;

        while (c.XPending(self.display) > 0) {
            var event: c.XEvent = undefined;
            _ = c.XNextEvent(self.display, &event);

            switch (event.type) {
                c.KeyPress, c.KeyRelease => {
                    const key_event = event.xkey;
                    const pressed = (event.type == c.KeyPress);

                    // Update modifier state
                    self.modifier_state = 0;
                    if (key_event.state & c.ShiftMask != 0) self.modifier_state |= 0x01;
                    if (key_event.state & c.Mod1Mask != 0) self.modifier_state |= 0x02; // Alt
                    if (key_event.state & c.ControlMask != 0) self.modifier_state |= 0x04;
                    if (key_event.state & c.Mod4Mask != 0) self.modifier_state |= 0x08; // Meta/Super

                    // Convert X11 keycode to evdev keycode (X11 = evdev + 8)
                    const evdev_code: u32 = if (key_event.keycode >= 8) key_event.keycode - 8 else 0;

                    // Check for Ctrl+Q to quit
                    const keysym = c.XLookupKeysym(@constCast(&key_event), 0);
                    if (pressed and (self.modifier_state & 0x04) != 0 and (keysym == c.XK_q or keysym == c.XK_Q)) {
                        log.info("Ctrl+Q pressed, closing window", .{});
                        self.closed = true;
                        return false;
                    }

                    // Queue the key event for clients
                    if (self.key_event_count < backend.MAX_KEY_EVENTS) {
                        self.key_events[self.key_event_count] = .{
                            .key_code = evdev_code,
                            .modifiers = self.modifier_state,
                            .pressed = pressed,
                        };
                        self.key_event_count += 1;
                    }
                },
                c.ButtonPress, c.ButtonRelease => {
                    const btn_event = event.xbutton;
                    const pressed = (event.type == c.ButtonPress);

                    // Update modifier state from button event
                    self.modifier_state = 0;
                    if (btn_event.state & c.ShiftMask != 0) self.modifier_state |= 0x01;
                    if (btn_event.state & c.Mod1Mask != 0) self.modifier_state |= 0x02;
                    if (btn_event.state & c.ControlMask != 0) self.modifier_state |= 0x04;
                    if (btn_event.state & c.Mod4Mask != 0) self.modifier_state |= 0x08;

                    // Convert X11 button to our MouseButton enum
                    const button: backend.MouseButton = switch (btn_event.button) {
                        1 => .left,
                        2 => .middle,
                        3 => .right,
                        4 => .scroll_up,
                        5 => .scroll_down,
                        6 => .scroll_left,
                        7 => .scroll_right,
                        8 => .button4,
                        9 => .button5,
                        else => .left,
                    };

                    // Queue the mouse event
                    if (self.mouse_event_count < backend.MAX_MOUSE_EVENTS) {
                        self.mouse_events[self.mouse_event_count] = .{
                            .x = @intCast(btn_event.x),
                            .y = @intCast(btn_event.y),
                            .button = button,
                            .event_type = if (pressed) .press else .release,
                            .modifiers = self.modifier_state,
                        };
                        self.mouse_event_count += 1;
                    }
                },
                c.MotionNotify => {
                    const motion_event = event.xmotion;

                    // Update modifier state from motion event
                    self.modifier_state = 0;
                    if (motion_event.state & c.ShiftMask != 0) self.modifier_state |= 0x01;
                    if (motion_event.state & c.Mod1Mask != 0) self.modifier_state |= 0x02;
                    if (motion_event.state & c.ControlMask != 0) self.modifier_state |= 0x04;
                    if (motion_event.state & c.Mod4Mask != 0) self.modifier_state |= 0x08;

                    // Determine which button is pressed during motion
                    const button: backend.MouseButton = if (motion_event.state & c.Button1Mask != 0)
                        .left
                    else if (motion_event.state & c.Button2Mask != 0)
                        .middle
                    else if (motion_event.state & c.Button3Mask != 0)
                        .right
                    else
                        .left;

                    // Queue the motion event
                    if (self.mouse_event_count < backend.MAX_MOUSE_EVENTS) {
                        self.mouse_events[self.mouse_event_count] = .{
                            .x = @intCast(motion_event.x),
                            .y = @intCast(motion_event.y),
                            .button = button,
                            .event_type = .motion,
                            .modifiers = self.modifier_state,
                        };
                        self.mouse_event_count += 1;
                    }
                },
                c.ConfigureNotify => {
                    const config = event.xconfigure;
                    if (@as(u32, @intCast(config.width)) != self.width or
                        @as(u32, @intCast(config.height)) != self.height)
                    {
                        log.info("window resized: {}x{}", .{ config.width, config.height });
                    }
                },
                c.SelectionRequest => {
                    self.handleSelectionRequest(&event.xselectionrequest);
                },
                c.SelectionNotify => {
                    self.handleSelectionNotify(&event.xselection);
                },
                else => {},
            }
        }

        return !self.closed;
    }

    // ========================================================================
    // Clipboard support (X11 selections)
    // ========================================================================

    fn handleSelectionRequest(self: *Self, req: *c.XSelectionRequestEvent) void {
        var notify: c.XSelectionEvent = undefined;
        notify.type = c.SelectionNotify;
        notify.display = req.display;
        notify.requestor = req.requestor;
        notify.selection = req.selection;
        notify.target = req.target;
        notify.property = req.property;
        notify.time = req.time;

        // Get the data for the requested selection
        const data = if (req.selection == self.atom_clipboard)
            self.clipboard_data
        else if (req.selection == self.atom_primary)
            self.primary_data
        else
            null;

        if (data) |content| {
            if (req.target == self.atom_targets) {
                // Return supported targets
                var targets = [_]Atom{ self.atom_targets, self.atom_utf8_string, self.atom_string };
                _ = c.XChangeProperty(
                    self.display,
                    req.requestor,
                    req.property,
                    self.atom_atom,
                    32,
                    c.PropModeReplace,
                    @ptrCast(&targets),
                    3,
                );
            } else if (req.target == self.atom_utf8_string or req.target == self.atom_string) {
                // Return the text content
                _ = c.XChangeProperty(
                    self.display,
                    req.requestor,
                    req.property,
                    req.target,
                    8,
                    c.PropModeReplace,
                    content.ptr,
                    @intCast(content.len),
                );
            } else {
                // Unsupported target
                notify.property = c.None;
            }
        } else {
            // No data available
            notify.property = c.None;
        }

        // Send the notification
        _ = c.XSendEvent(self.display, req.requestor, c.False, 0, @ptrCast(&notify));
        _ = c.XFlush(self.display);
    }

    fn handleSelectionNotify(self: *Self, notify: *c.XSelectionEvent) void {
        if (notify.property == c.None) {
            self.clipboard_request_pending = false;
            return;
        }

        // Read the selection data
        var actual_type: Atom = undefined;
        var actual_format: c_int = undefined;
        var nitems: c_ulong = undefined;
        var bytes_after: c_ulong = undefined;
        var prop_data: [*c]u8 = undefined;

        const result = c.XGetWindowProperty(
            self.display,
            self.window,
            notify.property,
            0,
            1024 * 1024, // Max 1MB
            c.True, // Delete after reading
            c.AnyPropertyType,
            &actual_type,
            &actual_format,
            &nitems,
            &bytes_after,
            &prop_data,
        );

        if (result == c.Success and prop_data != null and nitems > 0) {
            const len: usize = @intCast(nitems);
            const text = prop_data[0..len];

            // Store the clipboard data
            if (notify.selection == self.atom_clipboard) {
                if (self.clipboard_data) |old| {
                    self.allocator.free(old);
                }
                self.clipboard_data = self.allocator.dupe(u8, text) catch null;
            } else if (notify.selection == self.atom_primary) {
                if (self.primary_data) |old| {
                    self.allocator.free(old);
                }
                self.primary_data = self.allocator.dupe(u8, text) catch null;
            }

            _ = c.XFree(prop_data);
        }

        self.clipboard_request_pending = false;
    }

    /// Set clipboard content (selection: 0=CLIPBOARD, 1=PRIMARY)
    pub fn setClipboard(self: *Self, selection: u8, text: []const u8) !void {
        if (self.display == null) return error.NotInitialized;

        const atom = if (selection == 0) self.atom_clipboard else self.atom_primary;

        // Store the data
        if (selection == 0) {
            if (self.clipboard_data) |old| {
                self.allocator.free(old);
            }
            self.clipboard_data = try self.allocator.dupe(u8, text);
        } else {
            if (self.primary_data) |old| {
                self.allocator.free(old);
            }
            self.primary_data = try self.allocator.dupe(u8, text);
        }

        // Take ownership of the selection
        _ = c.XSetSelectionOwner(self.display, atom, self.window, c.CurrentTime);
        _ = c.XFlush(self.display);

        log.debug("clipboard set: selection={} len={}", .{ selection, text.len });
    }

    /// Request clipboard content (selection: 0=CLIPBOARD, 1=PRIMARY)
    pub fn requestClipboard(self: *Self, selection: u8) void {
        if (self.display == null) return;

        const atom = if (selection == 0) self.atom_clipboard else self.atom_primary;
        const property = c.XInternAtom(self.display, "SEMADRAW_CLIP", c.False);

        self.clipboard_request_selection = selection;
        self.clipboard_request_pending = true;

        _ = c.XConvertSelection(
            self.display,
            atom,
            self.atom_utf8_string,
            property,
            self.window,
            c.CurrentTime,
        );
        _ = c.XFlush(self.display);
    }

    /// Get the most recently received clipboard data
    pub fn getClipboardData(self: *Self, selection: u8) ?[]const u8 {
        if (selection == 0) {
            return self.clipboard_data;
        } else {
            return self.primary_data;
        }
    }

    /// Check if a clipboard request is pending
    pub fn isClipboardRequestPending(self: *Self) bool {
        return self.clipboard_request_pending;
    }

    fn getKeyEventsImpl(ctx: *anyopaque) []const backend.KeyEvent {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const count = self.key_event_count;
        self.key_event_count = 0; // Clear the queue
        return self.key_events[0..count];
    }

    fn getMouseEventsImpl(ctx: *anyopaque) []const backend.MouseEvent {
        const self: *Self = @ptrCast(@alignCast(ctx));
        const count = self.mouse_event_count;
        self.mouse_event_count = 0; // Clear the queue
        return self.mouse_events[0..count];
    }

    fn setClipboardImpl(ctx: *anyopaque, selection: u8, text: []const u8) anyerror!void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.setClipboard(selection, text);
    }

    fn requestClipboardImpl(ctx: *anyopaque, selection: u8) void {
        const self: *Self = @ptrCast(@alignCast(ctx));
        self.requestClipboard(selection);
    }

    fn getClipboardDataImpl(ctx: *anyopaque, selection: u8) ?[]const u8 {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.getClipboardData(selection);
    }

    fn isClipboardPendingImpl(ctx: *anyopaque) bool {
        const self: *Self = @ptrCast(@alignCast(ctx));
        return self.isClipboardRequestPending();
    }

    pub const vtable = backend.Backend.VTable{
        .getCapabilities = getCapabilitiesImpl,
        .initFramebuffer = initFramebufferImpl,
        .render = renderImpl,
        .getPixels = getPixelsImpl,
        .resize = resizeImpl,
        .pollEvents = pollEventsImpl,
        .getKeyEvents = getKeyEventsImpl,
        .getMouseEvents = getMouseEventsImpl,
        .setClipboard = setClipboardImpl,
        .requestClipboard = requestClipboardImpl,
        .getClipboardData = getClipboardDataImpl,
        .isClipboardPending = isClipboardPendingImpl,
        .deinit = deinitImpl,
    };

    pub fn toBackend(self: *Self) backend.Backend {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }
};

/// Create a Vulkan backend
pub fn create(allocator: std.mem.Allocator) !backend.Backend {
    const vk = try VulkanBackend.init(allocator);
    return vk.toBackend();
}
