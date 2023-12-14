"""Aspects to build and collect project dependencies."""

load(
    "@bazel_tools//tools/build_defs/cc:action_names.bzl",
    "CPP_COMPILE_ACTION_NAME",
    "C_COMPILE_ACTION_NAME",
)

ALWAYS_BUILD_RULES = "java_proto_library,java_lite_proto_library,java_mutable_proto_library,kt_proto_library_helper,_java_grpc_library,_java_lite_grpc_library,kt_grpc_library_helper,java_stubby_library,aar_import,java_import"

PROTO_RULE_KINDS = [
    "java_proto_library",
    "java_lite_proto_library",
    "java_mutable_proto_library",
    "kt_proto_library_helper",
]

def _package_dependencies_impl(target, ctx):
    java_info_file = _write_java_target_info(target, ctx)
    cc_info_file = _write_cc_target_info(target, ctx)

    return [OutputGroupInfo(
        qsync_jars = target[DependenciesInfo].compile_time_jars.to_list(),
        artifact_info_file = java_info_file,
        qsync_aars = target[DependenciesInfo].aars.to_list(),
        qsync_gensrcs = target[DependenciesInfo].gensrcs.to_list(),
        qsync_android_manifests = target[DependenciesInfo].android_manifest_files.to_list(),
        cc_headers = target[DependenciesInfo].cc_headers.to_list(),
        cc_info_file = cc_info_file + [target[DependenciesInfo].cc_toolchain_info.file] if target[DependenciesInfo].cc_toolchain_info else [],
    )]

def _write_java_target_info(target, ctx):
    if not target[DependenciesInfo].target_to_artifacts:
        return []
    file_name = target.label.name + ".java-info.txt"
    artifact_info_file = ctx.actions.declare_file(file_name)
    ctx.actions.write(
        artifact_info_file,
        _encode_target_info_proto(target[DependenciesInfo].target_to_artifacts),
    )
    return [artifact_info_file]

def _write_cc_target_info(target, ctx):
    if not target[DependenciesInfo].cc_info:
        return []
    cc_info_file_name = target.label.name + ".cc-info.txt"
    cc_info_file = ctx.actions.declare_file(cc_info_file_name)
    ctx.actions.write(
        cc_info_file,
        _encode_cc_info_proto(target.label, target[DependenciesInfo].cc_info),
    )
    return [cc_info_file]

DependenciesInfo = provider(
    "The out-of-project dependencies",
    fields = {
        "compile_time_jars": "a list of jars generated by targets",
        "target_to_artifacts": "a map between a target and all its artifacts",
        "aars": "a list of aars with resource files",
        "gensrcs": "a list of sources generated by project targets",
        "android_manifest_files": "a list of files containing android resources package names",
        "expand_sources": "boolean, true if the sources for this target should be expanded when it appears inside another rules srcs list",
        "cc_info": "a structure containing info required to compile cc sources",
        "cc_headers": "a depset of generated headers required to compile cc sources",
        "cc_toolchain_info": "struct containing cc toolchain info, with keys file (the output file) and id (unique ID for the toolchain info, referred to from elsewhere)",
        "test_mode_own_files": "a structure describing Java artifacts required when the target is requested within the project scope",
        "test_mode_cc_src_deps": "a list of sources (e.g. headers) required to compile cc sources in integratrion tests",
    },
)

def create_dependencies_info(
        compile_time_jars = depset(),
        target_to_artifacts = {},
        aars = depset(),
        gensrcs = depset(),
        android_manifest_files = depset(),
        expand_sources = False,
        cc_info = None,
        cc_headers = depset(),
        cc_toolchain_info = None,
        test_mode_own_files = None,
        test_mode_cc_src_deps = depset()):
    """A helper function to create a DependenciesInfo provider instance."""
    return DependenciesInfo(
        compile_time_jars = compile_time_jars,
        target_to_artifacts = target_to_artifacts,
        aars = aars,
        gensrcs = gensrcs,
        expand_sources = expand_sources,
        cc_info = cc_info,
        cc_headers = cc_headers,
        cc_toolchain_info = cc_toolchain_info,
        android_manifest_files = android_manifest_files,
        test_mode_own_files = test_mode_own_files,
        test_mode_cc_src_deps = test_mode_cc_src_deps,
    )

def _encode_target_info_proto(target_to_artifacts):
    contents = []
    for label, target_info in target_to_artifacts.items():
        contents.append(
            struct(
                target = label,
                jars = target_info["jars"],
                ide_aars = target_info["ide_aars"],
                gen_srcs = target_info["gen_srcs"],
                srcs = target_info["srcs"],
                srcjars = target_info["srcjars"],
                android_manifest_file = target_info["android_manifest_file"],
            ),
        )
    return proto.encode_text(struct(artifacts = contents))

def _encode_cc_info_proto(label, cc_info):
    return proto.encode_text(
        struct(targets = [
            struct(
                label = str(label),
                defines = cc_info.transitive_defines,
                include_directories = cc_info.transitive_include_directory,
                quote_include_directories = cc_info.transitive_quote_include_directory,
                system_include_directories = cc_info.transitive_system_include_directory,
                framework_include_directories = cc_info.framework_include_directory,
                gen_hdrs = cc_info.gen_headers,
                toolchain_id = cc_info.toolchain_id,
            ),
        ]),
    )

package_dependencies = aspect(
    implementation = _package_dependencies_impl,
    required_aspect_providers = [[DependenciesInfo]],
)

def declares_android_resources(target, ctx):
    """
    Returns true if the target has resource files and an android provider.

    The IDE needs aars from targets that declare resources. AndroidIdeInfo
    has a defined_android_resources flag, but this returns true for additional
    cases (aidl files, etc), so we check if the target has resource files.

    Args:
      target: the target.
      ctx: the context.
    Returns:
      True if the target has resource files and an android provider.
    """
    if AndroidIdeInfo not in target:
        return False
    return hasattr(ctx.rule.attr, "resource_files") and len(ctx.rule.attr.resource_files) > 0

def declares_aar_import(ctx):
    """
    Returns true if the target has aar and is aar_import rule.

    Args:
      ctx: the context.
    Returns:
      True if the target has aar and is aar_import rule.
    """
    return ctx.rule.kind == "aar_import" and hasattr(ctx.rule.attr, "aar")

def _collect_dependencies_impl(target, ctx):
    return _collect_dependencies_core_impl(
        target,
        ctx,
        ctx.attr.include,
        ctx.attr.exclude,
        ctx.attr.always_build_rules,
        ctx.attr.generate_aidl_classes,
        test_mode = False,
    )

def _collect_all_dependencies_for_tests_impl(target, ctx):
    return _collect_dependencies_core_impl(
        target,
        ctx,
        include = None,
        exclude = None,
        always_build_rules = ALWAYS_BUILD_RULES,
        generate_aidl_classes = None,
        test_mode = True,
    )

def _target_within_project_scope(label, include, exclude):
    result = False
    if include:
        for inc in include.split(","):
            if label.startswith(inc):
                if label[len(inc)] in [":", "/"]:
                    result = True
                    break
    if result and len(exclude) > 0:
        for exc in exclude.split(","):
            if label.startswith(exc):
                if label[len(exc)] in [":", "/"]:
                    result = False
                    break
    return result

def _get_followed_java_dependency_infos(rule):
    deps = []
    for (attr, kinds) in FOLLOW_JAVA_ATTRIBUTES_BY_RULE_KIND:
        if hasattr(rule.attr, attr) and (not kinds or rule.kind in kinds):
            to_add = getattr(rule.attr, attr)
            if type(to_add) == "list":
                deps += [t for t in to_add if type(t) == "Target"]
            elif type(to_add) == "Target":
                deps.append(to_add)

    return {
        str(dep.label): dep[DependenciesInfo]
        for dep in deps
        if DependenciesInfo in dep and dep[DependenciesInfo].target_to_artifacts
    }

def _collect_own_java_artifacts(
        target,
        ctx,
        dependency_infos,
        always_build_rules,
        generate_aidl_classes,
        target_is_within_project_scope):
    rule = ctx.rule

    # Toolchains are collected for proto targets via aspect traversal, but jars
    # produced for proto deps of the underlying proto_library are not
    can_follow_dependencies = bool(dependency_infos) and not ctx.rule.kind in PROTO_RULE_KINDS

    must_build_main_artifacts = (
        not target_is_within_project_scope or rule.kind in always_build_rules.split(",")
    )

    own_jar_files = []
    own_jar_depsets = []
    own_ide_aar_files = []
    own_gensrc_files = []
    own_src_files = []
    own_srcjar_files = []
    own_android_manifest = None

    if must_build_main_artifacts:
        # For rules that we do not follow dependencies of (either because they don't
        # have further dependencies with JavaInfo or do so in attributes we don't care)
        # we gather all their transitive dependencies. If they have dependencies, we
        # only gather their own compile jars and continue down the tree.
        # This is done primarily for rules like proto, whose toolchain classes
        # are collected via attribute traversal, but still requires jars for any
        # proto deps of the underlying proto_library.
        if JavaInfo in target:
            if can_follow_dependencies:
                own_jar_depsets.append(target[JavaInfo].compile_jars)
            else:
                own_jar_depsets.append(target[JavaInfo].transitive_compile_time_jars)

        if declares_android_resources(target, ctx):
            ide_aar = _get_ide_aar_file(target, ctx)
            if ide_aar:
                own_ide_aar_files.append(ide_aar)
        elif declares_aar_import(ctx):
            own_ide_aar_files.append(rule.attr.aar.files.to_list()[0])

    else:
        if AndroidIdeInfo in target:
            android_sdk_info = None
            if hasattr(rule.attr, "_android_sdk"):
                android_sdk_info = rule.attr._android_sdk[AndroidSdkInfo]

            # Export the manifest file to the IDE can read the package name from it
            # Note that while AndroidIdeInfo has a `java_package` API, it cannot always
            # determine the package name, since the it may only appear inside the
            # AndroidManifest.xml file which cannot be read by an aspect. So instead of
            # using that, we extract the use the manifest directly
            if target[AndroidIdeInfo].defines_android_resources and android_sdk_info:
                own_android_manifest = target[AndroidIdeInfo].manifest

            if generate_aidl_classes:
                add_base_idl_jar = False
                idl_jar = target[AndroidIdeInfo].idl_class_jar
                if idl_jar != None:
                    own_jar_files.append(idl_jar)
                    add_base_idl_jar = True

                generated_java_files = target[AndroidIdeInfo].idl_generated_java_files
                if generated_java_files:
                    own_gensrc_files += generated_java_files
                    add_base_idl_jar = True

                # An AIDL base jar needed for resolving base classes for aidl generated stubs.
                if add_base_idl_jar and android_sdk_info:
                    own_jar_depsets.append(android_sdk_info.aidl_lib.files)

        # Add generated java_outputs (e.g. from annotation processing)
        generated_class_jars = []
        if JavaInfo in target:
            for java_output in target[JavaInfo].java_outputs:
                # Prefer source jars if they exist:
                if java_output.generated_source_jar:
                    own_gensrc_files.append(java_output.generated_source_jar)
                elif java_output.generated_class_jar:
                    generated_class_jars.append(java_output.generated_class_jar)

        if generated_class_jars:
            own_jar_files += generated_class_jars

        # Add generated sources for included targets
        if hasattr(rule.attr, "srcs"):
            for src in rule.attr.srcs:
                for file in src.files.to_list():
                    if not file.is_source:
                        expand_sources = False
                        if str(file.owner) in dependency_infos:
                            src_depinfo = dependency_infos[str(file.owner)]
                            expand_sources = src_depinfo.expand_sources

                        # If the target that generates this source specifies that
                        # the sources should be expanded, we ignore the generated
                        # sources - the IDE will substitute the target sources
                        # themselves instead.
                        if not expand_sources:
                            own_gensrc_files.append(file)

    if not target_is_within_project_scope:
        if hasattr(rule.attr, "srcs"):
            for src in rule.attr.srcs:
                for file in src.files.to_list():
                    if file.is_source:
                        own_src_files.append(file.path)
                    else:
                        own_gensrc_files.append(file)
        if hasattr(rule.attr, "srcjar"):
            if rule.attr.srcjar and type(rule.attr.srcjar) == "Target":
                for file in rule.attr.srcjar.files.to_list():
                    if file.is_source:
                        own_srcjar_files.append(file.path)
                    else:
                        own_gensrc_files.append(file)

    return struct(
        jars = own_jar_files,
        jar_depsets = own_jar_depsets,
        ide_aars = own_ide_aar_files,
        gensrcs = own_gensrc_files,
        srcs = own_src_files,
        srcjars = own_srcjar_files,
        android_manifest_file = own_android_manifest,
    )

def _collect_own_and_dependency_java_artifacts(
        target,
        ctx,
        dependency_infos,
        always_build_rules,
        generate_aidl_classes,
        target_is_within_project_scope):
    own_files = _collect_own_java_artifacts(
        target,
        ctx,
        dependency_infos,
        always_build_rules,
        generate_aidl_classes,
        target_is_within_project_scope,
    )

    has_own_artifacts = (
        len(own_files.jars) +
        len(own_files.jar_depsets) +
        len(own_files.ide_aars) +
        len(own_files.gensrcs) +
        len(own_files.srcs) +
        len(own_files.srcjars) +
        (1 if own_files.android_manifest_file else 0)
    ) > 0

    target_to_artifacts = {}
    if has_own_artifacts:
        jars = depset(own_files.jars, transitive = own_files.jar_depsets).to_list()

        # Pass the following lists through depset() too to remove any duplicates.
        ide_aars = depset(own_files.ide_aars).to_list()
        gen_srcs = depset(own_files.gensrcs).to_list()
        target_to_artifacts[str(target.label)] = {
            "jars": [_output_relative_path(file.path) for file in jars],
            "ide_aars": [_output_relative_path(file.path) for file in ide_aars],
            "gen_srcs": [_output_relative_path(file.path) for file in gen_srcs],
            "srcs": own_files.srcs,
            "srcjars": own_files.srcjars,
            "android_manifest_file": own_files.android_manifest_file.path if own_files.android_manifest_file else None,
        }

    own_and_transitive_jar_depsets = list(own_files.jar_depsets)  # Copy to prevent changes to own_jar_depsets.
    own_and_transitive_ide_aar_depsets = []
    own_and_transitive_gensrc_depsets = []
    own_and_transitive_android_manifest_files = []

    for info in dependency_infos.values():
        target_to_artifacts.update(info.target_to_artifacts)
        own_and_transitive_jar_depsets.append(info.compile_time_jars)
        own_and_transitive_ide_aar_depsets.append(info.aars)
        own_and_transitive_android_manifest_files.append(info.android_manifest_files)

    return (
        target_to_artifacts,
        depset(own_files.jars, transitive = own_and_transitive_jar_depsets),
        depset(own_files.ide_aars, transitive = own_and_transitive_ide_aar_depsets),
        depset(own_files.gensrcs, transitive = own_and_transitive_gensrc_depsets),
        depset([own_files.android_manifest_file] if own_files.android_manifest_file else [], transitive = own_and_transitive_android_manifest_files),
    )

def _get_followed_cc_dependency_info(rule):
    if hasattr(rule.attr, "_cc_toolchain"):
        cc_toolchain_target = getattr(rule.attr, "_cc_toolchain")
        if DependenciesInfo in cc_toolchain_target:
            return cc_toolchain_target[DependenciesInfo]
    return None

def _collect_own_and_dependency_cc_info(target, dependency_info, test_mode):
    compilation_context = target[CcInfo].compilation_context
    cc_toolchain_info = None
    test_mode_cc_src_deps = depset()
    if dependency_info:
        cc_toolchain_info = dependency_info.cc_toolchain_info
        if test_mode:
            test_mode_cc_src_deps = dependency_info.test_mode_cc_src_deps

    gen_headers = depset()
    compilation_info = None
    if compilation_context:
        gen_headers = depset([f for f in compilation_context.headers.to_list() if not f.is_source])

        if test_mode:
            test_mode_cc_src_deps = depset(
                [f for f in compilation_context.headers.to_list() if f.is_source],
                transitive = [test_mode_cc_src_deps],
            )

        compilation_info = struct(
            transitive_defines = compilation_context.defines.to_list(),
            transitive_include_directory = compilation_context.includes.to_list(),
            transitive_quote_include_directory = compilation_context.quote_includes.to_list(),
            transitive_system_include_directory = compilation_context.system_includes.to_list() + compilation_context.external_includes.to_list(),
            framework_include_directory = compilation_context.framework_includes.to_list(),
            gen_headers = [f.path for f in gen_headers.to_list()],
            toolchain_id = cc_toolchain_info.id if cc_toolchain_info else None,
        )
    return struct(
        compilation_info = compilation_info,
        gen_headers = gen_headers,
        test_mode_cc_src_deps = test_mode_cc_src_deps,
        cc_toolchain_info = cc_toolchain_info,
    )

def _collect_dependencies_core_impl(
        target,
        ctx,
        include,
        exclude,
        always_build_rules,
        generate_aidl_classes,
        test_mode):
    dep_infos = _collect_java_dependencies_core_impl(
        target,
        ctx,
        include,
        exclude,
        always_build_rules,
        generate_aidl_classes,
        test_mode,
    )
    if CcInfo in target:
        dep_infos.append(_collect_cc_dependencies_core_impl(target, ctx, test_mode))
    if cc_common.CcToolchainInfo in target:
        dep_infos.append(_collect_cc_toolchain_info(target, ctx))
    return dep_infos

def _collect_java_dependencies_core_impl(
        target,
        ctx,
        include,
        exclude,
        always_build_rules,
        generate_aidl_classes,
        test_mode):
    target_is_within_project_scope = _target_within_project_scope(str(target.label), include, exclude) and not test_mode
    dependency_infos = _get_followed_java_dependency_infos(ctx.rule)

    target_to_artifacts, compile_jars, aars, gensrcs, android_manifest_files = _collect_own_and_dependency_java_artifacts(
        target,
        ctx,
        dependency_infos,
        always_build_rules,
        generate_aidl_classes,
        target_is_within_project_scope,
    )

    test_mode_own_files = None
    if test_mode:
        within_scope_own_files = _collect_own_java_artifacts(
            target,
            ctx,
            dependency_infos,
            always_build_rules,
            generate_aidl_classes,
            target_is_within_project_scope = True,
        )
        test_mode_own_files = struct(
            test_mode_within_scope_own_jar_files = depset(within_scope_own_files.jars, transitive = within_scope_own_files.jar_depsets).to_list(),
            test_mode_within_scope_own_ide_aar_files = within_scope_own_files.ide_aars,
            test_mode_within_scope_own_gensrc_files = within_scope_own_files.gensrcs,
            test_mode_within_scope_own_android_pname_files = within_scope_own_files.android_manifest_file,
        )

    expand_sources = False
    if hasattr(ctx.rule.attr, "tags"):
        if "ij-ignore-source-transform" in ctx.rule.attr.tags:
            expand_sources = True

    return [
        create_dependencies_info(
            target_to_artifacts = target_to_artifacts,
            compile_time_jars = compile_jars,
            aars = aars,
            gensrcs = gensrcs,
            expand_sources = expand_sources,
            test_mode_own_files = test_mode_own_files,
            android_manifest_files = android_manifest_files,
        ),
    ]

def _collect_cc_dependencies_core_impl(target, ctx, test_mode):
    dependency_info = _get_followed_cc_dependency_info(ctx.rule)

    cc_info = _collect_own_and_dependency_cc_info(target, dependency_info, test_mode)

    return create_dependencies_info(
        cc_info = cc_info.compilation_info,
        cc_headers = cc_info.gen_headers,
        cc_toolchain_info = cc_info.cc_toolchain_info,
        test_mode_cc_src_deps = cc_info.test_mode_cc_src_deps,
    )

def _collect_cc_toolchain_info(target, ctx):
    toolchain_info = target[cc_common.CcToolchainInfo]

    cpp_fragment = ctx.fragments.cpp

    # TODO(b/301235884): This logic is not quite right. `ctx` here is the context for the
    #  cc_toolchain target itself, so the `features` and `disabled_features` were using here are
    #  for the cc_toolchain, not the individual targets that this information will ultimately be
    #  used for. Instead, we should attach `toolchain_info` itself to the `DependenciesInfo`
    #  provider, and execute this logic once per top level cc target that we're building, to ensure
    #  that the right features are used.
    feature_config = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = toolchain_info,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features + [
            # Note: module_maps appears to be necessary here to ensure the API works
            # in all cases, and to avoid the error:
            # Invalid toolchain configuration: Cannot find variable named 'module_name'
            # yaqs/3227912151964319744
            "module_maps",
        ],
    )
    c_variables = cc_common.create_compile_variables(
        feature_configuration = feature_config,
        cc_toolchain = toolchain_info,
        user_compile_flags = cpp_fragment.copts + cpp_fragment.conlyopts,
    )
    cpp_variables = cc_common.create_compile_variables(
        feature_configuration = feature_config,
        cc_toolchain = toolchain_info,
        user_compile_flags = cpp_fragment.copts + cpp_fragment.cxxopts,
    )
    c_options = cc_common.get_memory_inefficient_command_line(
        feature_configuration = feature_config,
        action_name = C_COMPILE_ACTION_NAME,
        variables = c_variables,
    )
    cpp_options = cc_common.get_memory_inefficient_command_line(
        feature_configuration = feature_config,
        action_name = CPP_COMPILE_ACTION_NAME,
        variables = cpp_variables,
    )
    toolchain_id = str(target.label) + "%" + toolchain_info.target_gnu_system_name

    cc_toolchain_info = struct(
        id = toolchain_id,
        compiler_executable = toolchain_info.compiler_executable,
        cpu = toolchain_info.cpu,
        compiler = toolchain_info.compiler,
        target_name = toolchain_info.target_gnu_system_name,
        built_in_include_directories = toolchain_info.built_in_include_directories,
        c_options = c_options,
        cpp_options = cpp_options,
    )

    cc_toolchain_file_name = target.label.name + "." + cc_toolchain_info.target_name + ".txt"
    cc_toolchain_file = ctx.actions.declare_file(cc_toolchain_file_name)
    ctx.actions.write(
        cc_toolchain_file,
        proto.encode_text(
            struct(toolchains = cc_toolchain_info),
        ),
    )

    return create_dependencies_info(
        cc_toolchain_info = struct(file = cc_toolchain_file, id = toolchain_id),
        test_mode_cc_src_deps = depset([f for f in toolchain_info.all_files.to_list() if f.is_source]),
    )

def _get_ide_aar_file(target, ctx):
    """
    Builds a resource only .aar file for the ide.

    The IDE requires just resource files and the manifest from the IDE.
    Moreover, there are cases when the existing rules fail to build a full .aar
    file from a library, on which other targets can still depend.

    The function builds a minimalistic .aar file that contains resources and the
    manifest only.
    """
    full_aar = target[AndroidIdeInfo].aar
    if full_aar:
        resource_files = _collect_resource_files(ctx)
        resource_map = _build_ide_aar_file_map(target[AndroidIdeInfo].manifest, resource_files)
        aar = ctx.actions.declare_file(full_aar.short_path.removesuffix(".aar") + "_ide/" + full_aar.basename)
        _package_ide_aar(ctx, aar, resource_map)
        return aar
    else:
        return None

def _collect_resource_files(ctx):
    """
    Collects the list of resource files from the target rule attributes.
    """

    # Unfortunately, there are no suitable bazel providers that describe
    # resource files used a target.
    # However, AndroidIdeInfo returns a reference to a so-called resource APK
    # file, which contains everything the IDE needs to load resources from a
    # given library. However, this format is currently supported by Android
    # Studio in the namespaced resource mode. We should consider conditionally
    # enabling support in Android Studio and use them in ASwB, instead of
    # building special .aar files for the IDE.
    resource_files = []
    for t in ctx.rule.attr.resource_files:
        for f in t.files.to_list():
            resource_files.append(f)
    return resource_files

def _build_ide_aar_file_map(manifest_file, resource_files):
    """
    Build the list of files and their paths as they have to appear in .aar.
    """
    file_map = {}
    file_map["AndroidManifest.xml"] = manifest_file
    for f in resource_files:
        res_dir_path = f.short_path \
            .removeprefix(android_common.resource_source_directory(f)) \
            .removeprefix("/")
        if res_dir_path:
            res_dir_path = "res/" + res_dir_path
            file_map[res_dir_path] = f
    return file_map

def _package_ide_aar(ctx, aar, file_map):
    """
    Declares a file and defines actions to build .aar according to file_map.
    """
    files_map_args = []
    files = []
    for aar_dir_path, f in file_map.items():
        files.append(f)
        files_map_args.append("%s=%s" % (aar_dir_path, f.path))

    ctx.actions.run(
        mnemonic = "GenerateIdeAar",
        executable = ctx.executable._build_zip,
        inputs = files,
        outputs = [aar],
        arguments = ["c", aar.path] + files_map_args,
    )

def _output_relative_path(path):
    """Get file path relative to the output path.

    Args:
         path: path of artifact path = (../repo_name)? + (root_fragment)? + relative_path

    Returns:
         path relative to the output path
    """
    if (path.startswith("blaze-out/")) or (path.startswith("bazel-out/")):
        # len("blaze-out/") or len("bazel-out/")
        path = path[10:]
    return path

# List of tuples containing:
#   1. An attribute for the aspect to traverse
#   2. A list of rule kinds to specify which rules for which the attribute labels
#      need to be added as dependencies. If empty, the attribute is followed for
#      all rules.
FOLLOW_JAVA_ATTRIBUTES_BY_RULE_KIND = [
    ("deps", []),
    ("exports", []),
    ("srcs", []),
    ("_junit", []),
    ("_aspect_proto_toolchain_for_javalite", []),
    ("_aspect_java_proto_toolchain", []),
    ("runtime", ["proto_lang_toolchain", "java_rpc_toolchain"]),
    ("_toolchain", ["_java_grpc_library", "_java_lite_grpc_library", "kt_jvm_library_helper", "android_library"]),
    ("kotlin_libs", ["kt_jvm_toolchain"]),
]

FOLLOW_CC_ATTRIBUTES = ["_cc_toolchain"]

FOLLOW_ATTRIBUTES = [attr for (attr, _) in FOLLOW_JAVA_ATTRIBUTES_BY_RULE_KIND] + FOLLOW_CC_ATTRIBUTES

collect_dependencies = aspect(
    implementation = _collect_dependencies_impl,
    provides = [DependenciesInfo],
    attr_aspects = FOLLOW_ATTRIBUTES,
    attrs = {
        "include": attr.string(
            doc = "Comma separated list of workspace paths included in the project as source. Any targets inside here will not be built.",
            mandatory = True,
        ),
        "exclude": attr.string(
            doc = "Comma separated list of exclusions to 'include'.",
            default = "",
        ),
        "always_build_rules": attr.string(
            doc = "Comma separated list of rules. Any targets belonging to these rules will be built, regardless of location",
            default = "",
        ),
        "generate_aidl_classes": attr.bool(
            doc = "If True, generates classes for aidl files included as source for the project targets",
            default = False,
        ),
        "_build_zip": attr.label(
            allow_files = True,
            cfg = "exec",
            executable = True,
            default = "@@bazel_tools//tools/zip:zipper",
        ),
    },
    fragments = ["cpp"],
)

collect_all_dependencies_for_tests = aspect(
    doc = """
    A variant of collect_dependencies aspect used by query sync integration
    tests.

    The difference is that collect_all_dependencies does not apply
    include/exclude directory filtering, which is applied in the test framework
    instead. See: test_project.bzl for more details.
    """,
    implementation = _collect_all_dependencies_for_tests_impl,
    provides = [DependenciesInfo],
    attr_aspects = FOLLOW_ATTRIBUTES,
    attrs = {
        "_build_zip": attr.label(
            allow_files = True,
            cfg = "exec",
            executable = True,
            default = "@@bazel_tools//tools/zip:zipper",
        ),
    },
    fragments = ["cpp"],
)
