const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const semadraw_root = b.path("src/semadraw.zig");
    const sdcs_root = b.path("src/sdcs.zig");

    // Zig 0.15+ build API uses explicit root modules.
    const semadraw_mod = b.createModule(.{
        .root_source_file = semadraw_root,
        .target = target,
        .optimize = optimize,
    });
    const sdcs_mod = b.createModule(.{
        .root_source_file = sdcs_root,
        .target = target,
        .optimize = optimize,
    });

    // Static library
    const lib = b.addLibrary(.{
        .name = "semadraw",
        .root_module = semadraw_mod,
        .linkage = .static,
    });
    b.installArtifact(lib);

    // Tools
    const sdcs_dump = b.addExecutable(.{
        .name = "sdcs_dump",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/sdcs_dump.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    sdcs_dump.root_module.addImport("semadraw", semadraw_mod);
    sdcs_dump.root_module.addImport("sdcs", sdcs_mod);
    b.installArtifact(sdcs_dump);

    const sdcs_make_test = b.addExecutable(.{
        .name = "sdcs_make_test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/sdcs_make_test.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    sdcs_make_test.root_module.addImport("semadraw", semadraw_mod);
    sdcs_make_test.root_module.addImport("sdcs", sdcs_mod);
    b.installArtifact(sdcs_make_test);

    const sdcs_make_overlap = b.addExecutable(.{
        .name = "sdcs_make_overlap",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/sdcs_make_overlap.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    sdcs_make_overlap.root_module.addImport("semadraw", semadraw_mod);
    sdcs_make_overlap.root_module.addImport("sdcs", sdcs_mod);
    b.installArtifact(sdcs_make_overlap);

    const sdcs_make_fractional = b.addExecutable(.{
        .name = "sdcs_make_fractional",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/sdcs_make_fractional.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    sdcs_make_fractional.root_module.addImport("semadraw", semadraw_mod);
    sdcs_make_fractional.root_module.addImport("sdcs", sdcs_mod);
    b.installArtifact(sdcs_make_fractional);

    const sdcs_make_clip = b.addExecutable(.{
        .name = "sdcs_make_clip",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/sdcs_make_clip.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    sdcs_make_clip.root_module.addImport("semadraw", semadraw_mod);
    sdcs_make_clip.root_module.addImport("sdcs", sdcs_mod);
    b.installArtifact(sdcs_make_clip);

    const sdcs_make_transform = b.addExecutable(.{
        .name = "sdcs_make_transform",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/sdcs_make_transform.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    sdcs_make_transform.root_module.addImport("semadraw", semadraw_mod);
    sdcs_make_transform.root_module.addImport("sdcs", sdcs_mod);
    b.installArtifact(sdcs_make_transform);

    const sdcs_make_blend = b.addExecutable(.{
        .name = "sdcs_make_blend",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/sdcs_make_blend.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    sdcs_make_blend.root_module.addImport("semadraw", semadraw_mod);
    sdcs_make_blend.root_module.addImport("sdcs", sdcs_mod);
    b.installArtifact(sdcs_make_blend);
	const sdcs_make_stroke = b.addExecutable(.{
	    .name = "sdcs_make_stroke",
	    .root_module = b.createModule(.{
	        .root_source_file = b.path("src/tools/sdcs_make_stroke.zig"),
	        .target = target,
	        .optimize = optimize,
	    }),
	});
	sdcs_make_stroke.root_module.addImport("semadraw", semadraw_mod);
	sdcs_make_stroke.root_module.addImport("sdcs", sdcs_mod);
	b.installArtifact(sdcs_make_stroke);

	const sdcs_make_line = b.addExecutable(.{
	    .name = "sdcs_make_line",
	    .root_module = b.createModule(.{
	        .root_source_file = b.path("src/tools/sdcs_make_line.zig"),
	        .target = target,
	        .optimize = optimize,
	    }),
	});
	sdcs_make_line.root_module.addImport("semadraw", semadraw_mod);
	sdcs_make_line.root_module.addImport("sdcs", sdcs_mod);
	b.installArtifact(sdcs_make_line);

	const sdcs_make_join = b.addExecutable(.{
	    .name = "sdcs_make_join",
	    .root_module = b.createModule(.{
	        .root_source_file = b.path("src/tools/sdcs_make_join.zig"),
	        .target = target,
	        .optimize = optimize,
	    }),
	});
	sdcs_make_join.root_module.addImport("semadraw", semadraw_mod);
	sdcs_make_join.root_module.addImport("sdcs", sdcs_mod);
	b.installArtifact(sdcs_make_join);

	const sdcs_make_join_round = b.addExecutable(.{
	    .name = "sdcs_make_join_round",
	    .root_module = b.createModule(.{
	        .root_source_file = b.path("src/tools/sdcs_make_join_round.zig"),
	        .target = target,
	        .optimize = optimize,
	    }),
	});
	sdcs_make_join_round.root_module.addImport("semadraw", semadraw_mod);
	sdcs_make_join_round.root_module.addImport("sdcs", sdcs_mod);
	b.installArtifact(sdcs_make_join_round);

	const sdcs_make_cap = b.addExecutable(.{
	    .name = "sdcs_make_cap",
	    .root_module = b.createModule(.{
	        .root_source_file = b.path("src/tools/sdcs_make_cap.zig"),
	        .target = target,
	        .optimize = optimize,
	    }),
	});
	sdcs_make_cap.root_module.addImport("semadraw", semadraw_mod);
	sdcs_make_cap.root_module.addImport("sdcs", sdcs_mod);
	b.installArtifact(sdcs_make_cap);

	const sdcs_make_cap_round = b.addExecutable(.{
	    .name = "sdcs_make_cap_round",
	    .root_module = b.createModule(.{
	        .root_source_file = b.path("src/tools/sdcs_make_cap_round.zig"),
	        .target = target,
	        .optimize = optimize,
	    }),
	});
	sdcs_make_cap_round.root_module.addImport("semadraw", semadraw_mod);
	sdcs_make_cap_round.root_module.addImport("sdcs", sdcs_mod);
	b.installArtifact(sdcs_make_cap_round);

	const sdcs_make_miter_limit = b.addExecutable(.{
	    .name = "sdcs_make_miter_limit",
	    .root_module = b.createModule(.{
	        .root_source_file = b.path("src/tools/sdcs_make_miter_limit.zig"),
	        .target = target,
	        .optimize = optimize,
	    }),
	});
	sdcs_make_miter_limit.root_module.addImport("semadraw", semadraw_mod);
	sdcs_make_miter_limit.root_module.addImport("sdcs", sdcs_mod);
	b.installArtifact(sdcs_make_miter_limit);

	const sdcs_make_diagonal = b.addExecutable(.{
	    .name = "sdcs_make_diagonal",
	    .root_module = b.createModule(.{
	        .root_source_file = b.path("src/tools/sdcs_make_diagonal.zig"),
	        .target = target,
	        .optimize = optimize,
	    }),
	});
	sdcs_make_diagonal.root_module.addImport("semadraw", semadraw_mod);
	sdcs_make_diagonal.root_module.addImport("sdcs", sdcs_mod);
	b.installArtifact(sdcs_make_diagonal);

	const sdcs_make_blit = b.addExecutable(.{
	    .name = "sdcs_make_blit",
	    .root_module = b.createModule(.{
	        .root_source_file = b.path("src/tools/sdcs_make_blit.zig"),
	        .target = target,
	        .optimize = optimize,
	    }),
	});
	sdcs_make_blit.root_module.addImport("semadraw", semadraw_mod);
	sdcs_make_blit.root_module.addImport("sdcs", sdcs_mod);
	b.installArtifact(sdcs_make_blit);

	const sdcs_make_curves = b.addExecutable(.{
	    .name = "sdcs_make_curves",
	    .root_module = b.createModule(.{
	        .root_source_file = b.path("src/tools/sdcs_make_curves.zig"),
	        .target = target,
	        .optimize = optimize,
	    }),
	});
	sdcs_make_curves.root_module.addImport("semadraw", semadraw_mod);
	sdcs_make_curves.root_module.addImport("sdcs", sdcs_mod);
	b.installArtifact(sdcs_make_curves);

	const sdcs_make_path = b.addExecutable(.{
	    .name = "sdcs_make_path",
	    .root_module = b.createModule(.{
	        .root_source_file = b.path("src/tools/sdcs_make_path.zig"),
	        .target = target,
	        .optimize = optimize,
	    }),
	});
	sdcs_make_path.root_module.addImport("semadraw", semadraw_mod);
	sdcs_make_path.root_module.addImport("sdcs", sdcs_mod);
	b.installArtifact(sdcs_make_path);

	const sdcs_make_text = b.addExecutable(.{
	    .name = "sdcs_make_text",
	    .root_module = b.createModule(.{
	        .root_source_file = b.path("src/tools/sdcs_make_text.zig"),
	        .target = target,
	        .optimize = optimize,
	    }),
	});
	sdcs_make_text.root_module.addImport("semadraw", semadraw_mod);
	sdcs_make_text.root_module.addImport("sdcs", sdcs_mod);
	b.installArtifact(sdcs_make_text);

	const sdcs_make_aa = b.addExecutable(.{
	    .name = "sdcs_make_aa",
	    .root_module = b.createModule(.{
	        .root_source_file = b.path("src/tools/sdcs_make_aa.zig"),
	        .target = target,
	        .optimize = optimize,
	    }),
	});
	sdcs_make_aa.root_module.addImport("semadraw", semadraw_mod);
	b.installArtifact(sdcs_make_aa);

	const sdcs_make_demo = b.addExecutable(.{
	    .name = "sdcs_make_demo",
	    .root_module = b.createModule(.{
	        .root_source_file = b.path("src/tools/sdcs_make_demo.zig"),
	        .target = target,
	        .optimize = optimize,
	    }),
	});
	sdcs_make_demo.root_module.addImport("semadraw", semadraw_mod);
	b.installArtifact(sdcs_make_demo);

    const sdcs_replay = b.addExecutable(.{
        .name = "sdcs_replay",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/sdcs_replay.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    sdcs_replay.root_module.addImport("semadraw", semadraw_mod);
    sdcs_replay.root_module.addImport("sdcs", sdcs_mod);
    b.installArtifact(sdcs_replay);

    // Test tool for malformed inputs
    const sdcs_test_malformed = b.addExecutable(.{
        .name = "sdcs_test_malformed",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/sdcs_test_malformed.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    sdcs_test_malformed.root_module.addImport("semadraw", semadraw_mod);
    sdcs_test_malformed.root_module.addImport("sdcs", sdcs_mod);
    b.installArtifact(sdcs_test_malformed);

    // Fuzzing harness
    const sdcs_fuzz = b.addExecutable(.{
        .name = "sdcs_fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tools/sdcs_fuzz.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    sdcs_fuzz.root_module.addImport("semadraw", semadraw_mod);
    sdcs_fuzz.root_module.addImport("sdcs", sdcs_mod);
    b.installArtifact(sdcs_fuzz);

    // IPC protocol module (for semadrawd and clients)
    const ipc_protocol_mod = b.createModule(.{
        .root_source_file = b.path("src/ipc/protocol.zig"),
        .target = target,
        .optimize = optimize,
    });

    const ipc_socket_mod = b.createModule(.{
        .root_source_file = b.path("src/ipc/socket_server.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = ipc_protocol_mod },
        },
    });

    const ipc_shm_mod = b.createModule(.{
        .root_source_file = b.path("src/ipc/shm.zig"),
        .target = target,
        .optimize = optimize,
    });

    const client_session_mod = b.createModule(.{
        .root_source_file = b.path("src/daemon/client_session.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = ipc_protocol_mod },
            .{ .name = "socket_server", .module = ipc_socket_mod },
        },
    });

    const surface_registry_mod = b.createModule(.{
        .root_source_file = b.path("src/daemon/surface_registry.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "protocol", .module = ipc_protocol_mod },
        },
    });

    const sdcs_validator_mod = b.createModule(.{
        .root_source_file = b.path("src/daemon/sdcs_validator.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sdcs", .module = sdcs_mod },
        },
    });

    // Backend modules
    const backend_mod = b.createModule(.{
        .root_source_file = b.path("src/backend/backend.zig"),
        .target = target,
        .optimize = optimize,
    });

    const software_backend_mod = b.createModule(.{
        .root_source_file = b.path("src/backend/software.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "backend", .module = backend_mod },
        },
    });

    // Add software import to backend module for createBackend
    backend_mod.addImport("software", software_backend_mod);

    const backend_process_mod = b.createModule(.{
        .root_source_file = b.path("src/backend/process.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "backend", .module = backend_mod },
        },
    });

    // semadrawd daemon
    const semadrawd = b.addExecutable(.{
        .name = "semadrawd",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/daemon/semadrawd.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "protocol", .module = ipc_protocol_mod },
                .{ .name = "socket_server", .module = ipc_socket_mod },
                .{ .name = "client_session", .module = client_session_mod },
                .{ .name = "surface_registry", .module = surface_registry_mod },
                .{ .name = "shm", .module = ipc_shm_mod },
                .{ .name = "sdcs_validator", .module = sdcs_validator_mod },
                .{ .name = "backend", .module = backend_mod },
                .{ .name = "backend_process", .module = backend_process_mod },
            },
        }),
    });
    b.installArtifact(semadrawd);

    // Unit tests
    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/sdcs.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const run_tests = b.addRunArtifact(tests);

    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_tests.step);
}
