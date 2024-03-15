# Licensed to the Apache Software Foundation (ASF) under one or more
# contributor license agreements.  See the NOTICE file distributed with
# this work for additional information regarding copyright ownership.
# The ASF licenses this file to You under the Apache License, Version 2.0
# (the "License"); you may not use this file except in compliance with
# the License.  You may obtain a copy of the License at

#     http://www.apache.org/licenses/LICENSE-2.0

# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

load("//:plugin.bzl", "ProtoPluginInfo")

ProtoCompileInfo = provider(fields = {
    "label": "label object",
    "plugins": "ProtoPluginInfo object",
    "descriptor": "descriptor set file",
    "outputs": "generated protoc outputs",
    "files": "final generated files",
    "protos": "generated protos (copies)",
    "args": "proto arguments",
    "tools": "proto tools",
    "verbose": "verbose level",
})

def _get_plugin_out(ctx, plugin):
    if not plugin.out:
        return None
    filename = plugin.out
    filename = filename.replace("{name}", ctx.label.name)
    return filename


# From https://github.com/grpc/grpc/blob/2e7d6b94eaf6b0e11add27606b4fe3d0b7216154/bazel/protobuf.bzl:

_VIRTUAL_IMPORTS = "/_virtual_imports/"

def _strip_virtual_import(path):
      pos = path.find(_VIRTUAL_IMPORTS)
      path = path[pos + len(_VIRTUAL_IMPORTS):]
      return path.split("/", 1)[-1]

def _get_proto_filename(src):
    """Assemble the filename for a proto

    Args:
      src: the .proto <File>

    Returns:
      <string> of the filename.
    """
    parts = src.short_path.split("/")
    if len(parts) > 1 and parts[0] == "..":
        return "/".join(parts[2:])
    return src.short_path

def _apply_plugin_transitivity_rules(ctx, targets, plugin):
    """Process the proto target list according to plugin transitivity rules

    Args:
      ctx: the <ctx> object
      targets: the dict<string,File> of .proto files that we intend to compile.
      plugin: the <PluginInfo> object.

    Returns:
      <list<File>> the possibly filtered list of .proto <File>s
    """

    # Iterate transitivity rules like '{ "google/protobuf": "exclude" }'. The
    # only rule type implemented is "exclude", which checks if the pathname or
    # dirname ends with the given pattern.  If so, remove that item in the
    # targets list.
    #
    # Why does this feature exist?  Well, library rules like C# require all the
    # proto files to be present during the compilation (collected via transitive
    # sources).  However, since the well-known types are already present in the
    # library dependencies, we don't actually want to compile well-known types
    # (but do want to compile everything else).
    #
    transitivity = {}
    transitivity.update(plugin.transitivity)
    transitivity.update(ctx.attr.transitivity)

    for pattern, rule in transitivity.items():
        if rule == "exclude":
            for key, target in targets.items():
                if ctx.attr.verbose > 2:
                    print("Checking '%s' endswith '%s'" % (target.short_path, pattern))
                if target.dirname.endswith(pattern) or target.path.endswith(pattern):
                    targets.pop(key)
                    if ctx.attr.verbose > 2:
                        print("Removing '%s' from the list of files to compile as plugin '%s' excluded it" % (target.short_path, plugin.name))
                elif ctx.attr.verbose > 2:
                    print("Keeping '%s' (not excluded)" % (target.short_path))
        elif rule == "include":
            for key, target in targets.items():
                if target.dirname.endswith(pattern) or target.path.endswith(pattern):
                    if ctx.attr.verbose > 2:
                        print("Keeping '%s' (explicitly included)" % (target.short_path))
                else:
                    targets.pop(key)
                    if ctx.attr.verbose > 2:
                        print("Removing '%s' from the list of files to compile as plugin '%s' did not include it" % (target.short_path, plugin.name))
        else:
            fail("Unknown transitivity rule '%s'" % rule)
    return targets

def get_plugin_outputs(ctx, descriptor, outputs, src, proto, plugin):
    """Get the predicted generated outputs for a given plugin

    Args:
      ctx: the <ctx> object
      descriptor: the descriptor <Generated File>
      outputs: the list of outputs.
      src: the orginal .proto source <Source File>.
      proto: the copied .proto <Generated File> (the one in the package 'staging area')
      plugin: the <PluginInfo> object.

    Returns:
      <list<Generated File>> the augmented list of files that will be generated
    """
    for output in plugin.outputs:
        filename = _get_output_filename(src, plugin, output)
        if not filename:
            continue
        sibling = _get_output_sibling_file(output, proto, descriptor)
        outputs.append(ctx.actions.declare_file(filename, sibling = sibling))
    return outputs

def _get_output_filename(src, plugin, pattern):
    """Build the predicted filename for file generated by the given plugin.

    A 'proto_plugin' rule allows one to define the predicted outputs.  For
    flexibility, we allow special tokens in the output filename that get
    replaced here. The overall pattern is '{token}' mimicking the python
    'format' feature.

    Additionally, there are '|' characters like '{basename|pascal}' that can be
    read as 'take the basename and pipe that through the pascal function'.

    Args:
      src: the .proto <File>
      plugin: the <PluginInfo> object.
      pattern: the input pattern string

    Returns:
      the replaced string
    """

    # If output to srcjar, don't emit a per-proto output file.
    if plugin.out:
        return None

    # Slice off this prefix if it exists, we don't use it here.
    if pattern.startswith("{package}/"):
        pattern = pattern[len("{package}/"):]
    basename = src.basename
    if basename.endswith(".proto"):
        basename = basename[:-6]
    elif basename.endswith(".protodevel"):
        basename = basename[:-11]

    filename = basename

    if pattern.find("{basename}") != -1:
        filename = pattern.replace("{basename}", basename)
    elif pattern.find("{basename|pascal}") != -1:
        filename = pattern.replace("{basename|pascal}", _pascal_case(basename))
    elif pattern.find("{basename|pascal|objc}") != -1:
        filename = pattern.replace("{basename|pascal|objc}", _pascal_objc(basename))
    elif pattern.find("{basename|rust_keyword}") != -1:
        filename = pattern.replace("{basename|rust_keyword}", _rust_keyword(basename))
    else:
        filename = basename + pattern

    return filename

def _get_output_sibling_file(pattern, proto, descriptor):
    """Get the correct place to

    The ctx.actions.declare_file has a 'sibling = <File>' feature that allows
    one to declare files in the same directory as the sibling.

    This function checks for the prefix special token '{package}' and, if true,
    uses the descriptor as the sibling (which declares the output file will be
    in the root of the generated tree).

    Args:
      pattern: the input filename pattern <string>
      proto: the .proto <Generated File> (in the staging area)
      descriptor: the descriptor <File> that marks the staging root.

    Returns:
      the <File> to be used as the correct sibling.
    """

    if pattern.startswith("{package}/"):
        return descriptor
    return proto

rust_keywords = {
    "as": True,
    "break": True,
    "const": True,
    "continue": True,
    "crate": True,
    "else": True,
    "enum": True,
    "extern": True,
    "false": True,
    "fn": True,
    "for": True,
    "if": True,
    "impl": True,
    "let": True,
    "loop": True,
    "match": True,
    "mod": True,
    "move": True,
    "mut": True,
    "pub": True,
    "ref": True,
    "return": True,
    "self": True,
    "Self": True,
    "static": True,
    "struct": True,
    "super": True,
    "trait": True,
    "true": True,
    "type": True,
    "unsafe": True,
    "use": True,
    "where": True,
    "while": True,
}

objc_upper_segments = {
    "url": "URL",
    "http": "HTTP",
    "https": "HTTPS",
}

def _capitalize(s):
    """Capitalize a string - only first letter
    Args:
      s (string): The input string to be capitalized.
    Returns:
      (string): The capitalized string.
    """
    return s[0:1].upper() + s[1:]

def get_plugin_out_arg(ctx, outdir, plugin, plugin_outfiles):
    """Build the --java_out argument

    Args:
      ctx: the <ctx> object
      outdir: the package output directory <string>
      plugin: the <PluginInfo> object.
      plugin_outfiles: The <dict<string,<File>>.  For example, {closure: "library.js"}

    Returns
      <string> for the protoc arg list.
    """

    arg = outdir
    if plugin.outdir:
        arg = plugin.outdir.replace("{name}", outdir)
    elif plugin.out:
        outfile = plugin_outfiles[plugin.name]
        arg = outfile.path

    # Collate a list of options from the plugin itself PLUS options from the
    # global plugin_options list (if they exist)
    options = []
    options += getattr(plugin, "options", [])
    options += getattr(ctx.attr, "plugin_options", [])

    if options:
        arg = "%s:%s" % (",".join(_get_plugin_options(ctx, options)), arg)
    return "--%s_out=%s" % (plugin.name, arg)

def _get_plugin_options(ctx, options):
    """Build a plugin option list

    Args:
      ctx: the <ctx> object
      options: list<string> options from the <PluginInfo>

    Returns:
      <string> for the --plugin_out= arg
    """
    return [_get_plugin_option(ctx, option) for option in options]

def _get_plugin_option(ctx, option):
    """Build a plugin option

    Args:
      ctx: the <ctx> object
      option: string from the <PluginInfo>

    Returns:
      <string> for the --plugin_out= arg
    """
    return option.replace("{name}", ctx.label.name)

def _rust_keyword(s):
    """Check if arg is a rust keyword and append '_pb' if true.
    Args:
        s (string): The input string to be capitalized.
    Returns:
        (string): The appended string.
    """
    return s + "_pb" if rust_keywords.get(s) else s

def _pascal_objc(s):
    """Convert pascal_case -> PascalCase

    Objective C uses pascal case, but there are e exceptions that it uppercases
    the entire segment: url, http, and https.

    https://github.com/protocolbuffers/protobuf/blob/54176b26a9be6c9903b375596b778f51f5947921/src/google/protobuf/compiler/objectivec/objectivec_helpers.cc#L91

    Args:
      s (string): The input string to be capitalized.
    Returns: (string): The capitalized string.
    """
    segments = []
    for segment in s.split("_"):
        repl = objc_upper_segments.get(segment)
        if repl:
            segment = repl
        else:
            segment = _capitalize(segment)
        segments.append(segment)
    return "".join(segments)

def _pascal_case(s):
    """Convert pascal_case -> PascalCase
    Args:
        s (string): The input string to be capitalized.
    Returns:
        (string): The capitalized string.
    """
    return "".join([_capitalize(part) for part in s.split("_")])

def is_in_virtual_imports(source_file, virtual_folder = _VIRTUAL_IMPORTS):
    """Determines if source_file is virtual (is placed in _virtual_imports
    subdirectory). The output of all proto_library targets which use
    import_prefix  and/or strip_import_prefix arguments is placed under
    _virtual_imports directory.
    Args:
        source_file: A proto file.
        virtual_folder: The virtual folder name (is set to "_virtual_imports"
            by default)
    Returns:
        True if source_file is located under _virtual_imports, False otherwise.
    """
    return not source_file.is_source and virtual_folder in source_file.path

def copy_proto(ctx, descriptor, src):
    """Copy a proto to the 'staging area'

    Args:
      ctx: the <ctx> object
      descriptor: the descriptor <File> that marks the root of the 'staging area'.
      src: the source .proto <File>

    Returns:
      <Generated File> for the copied .proto
    """
    if is_in_virtual_imports(src):
        proto_rpath = _strip_virtual_import(src.path)
    else:
        proto_rpath = _get_proto_filename(src)
    proto_copy_path = "/".join([descriptor.dirname, proto_rpath])
    proto = ctx.actions.declare_file(proto_rpath, sibling = descriptor)

    ctx.actions.run_shell(
        mnemonic = "CopyProto",
        inputs = [src],
        outputs = [proto],
        command = "cp %s %s" % (src.path, proto_copy_path),
    )
    return proto

def _copy_jar_to_srcjar(ctx, jar):
    """Copy .jar to .srcjar

    Args:
      ctx: the <ctx> object
      jar: the <Generated File> of a jar containing source files.

    Returns:
      <Generated File> for the renamed file
    """
    srcjar = ctx.actions.declare_file("%s/%s.srcjar" % (ctx.label.name, ctx.label.name))
    ctx.actions.run_shell(
        mnemonic = "CopySrcjar",
        inputs = [jar],
        outputs = [srcjar],
        command = "mv %s %s" % (jar.path, srcjar.path),
    )
    return srcjar

def get_plugin_runfiles(tool):
    """Gather runfiles for a plugin.
    """
    files = []
    if not tool:
        return files

    info = tool[DefaultInfo]
    if not info:
        return files

    if info.files:
        files += info.files.to_list()

    if info.default_runfiles:
        runfiles = info.default_runfiles
        if runfiles.files:
            files += runfiles.files.to_list()

    if info.data_runfiles:
        runfiles = info.data_runfiles
        if runfiles.files:
            files += runfiles.files.to_list()

    return files

def proto_compile_impl(ctx):
    ###
    ### Part 1: setup variables used in scope
    ###

    # <int> verbose level
    verbose = ctx.attr.verbose

    # <File> the protoc tool
    protoc = ctx.executable.protoc

    # <File> for the output descriptor.  Often used as the sibling in
    # 'declare_file' actions.
    descriptor = ctx.outputs.descriptor

    # <string> The directory where that generated descriptor is.
    outdir = descriptor.dirname

    # <list<ProtoInfo>> A list of ProtoInfo
    deps = [dep[ProtoInfo] for dep in ctx.attr.deps]

    # <list<PluginInfo>> A list of PluginInfo
    plugins = [plugin[ProtoPluginInfo] for plugin in ctx.attr.plugins]

    # <list<File>> The list of .proto files that will exist in the 'staging
    # area'.  We copy them from their source location into place such that a
    # single '-I.' at the package root will satisfy all import paths.
    protos = []

    # <dict<string,File>> The set of .proto files to compile, used as the final
    # list of arguments to protoc.  This is a subset of the 'protos' list that
    # are directly specified in the proto_library deps, but excluding other
    # transitive .protos.  For example, even though we might transitively depend
    # on 'google/protobuf/any.proto', we don't necessarily want to actually
    # generate artifacts for it when compiling 'foo.proto'. Maintained as a dict
    # for set semantics.  The key is the value from File.path.
    targets = {}

    # <dict<string,File>> A mapping from plugin name to the plugin tool. Used to
    # generate the --plugin=protoc-gen-KEY=VALUE args
    plugin_tools = {}

    # <dict<string,<File> A mapping from PluginInfo.name to File.  In the case
    # of plugins that specify a single output 'archive' (like java), we gather
    # them in this dict.  It is used to generate args like
    # '--java_out=libjava.jar'.
    plugin_outfiles = {}

    # <list<File>> The list of srcjars that we're generating (like
    # 'foo.srcjar').
    srcjars = []

    # <list<File>> The list of generated artifacts like 'foo_pb2.py' that we
    # expect to be produced.
    outputs = []

    # Additional data files from plugin.data needed by plugin tools that are not
    # single binaries.
    data = []

    ###
    ### Part 2: gather plugin.out artifacts
    ###

    # Some protoc plugins generate a set of output files (like python) while
    # others generate a single 'archive' file that contains the individual
    # outputs (like java).  This first loop is for the latter type.  In this
    # scenario, the PluginInfo.out attribute will exist; the predicted file
    # output location is relative to the package root, marked by the descriptor
    # file. Jar outputs are gathered as a special case as we need to
    # post-process them to have a 'srcjar' extension (java_library rules don't
    # accept source jars with a 'jar' extension)
    for plugin in plugins:
        if plugin.executable:
            plugin_tools[plugin.name] = plugin.executable
        data += plugin.data + get_plugin_runfiles(plugin.tool)

        filename = _get_plugin_out(ctx, plugin)
        if not filename:
            continue
        out = ctx.actions.declare_file(filename, sibling = descriptor)
        outputs.append(out)
        plugin_outfiles[plugin.name] = out
        if out.path.endswith(".jar"):
            srcjar = _copy_jar_to_srcjar(ctx, out)
            srcjars.append(srcjar)

    ###
    ### Part 3a: Gather generated artifacts for each dependency .proto source file.
    ###

    for dep in deps:
        # Iterate all the directly specified .proto files.  If we have already
        # processed this one, skip it to avoid declaring duplicate outputs.
        # Create an action to copy the proto into our staging area.  Consult the
        # plugin to assemble the actual list of predicted generated artifacts
        # and save these in the 'outputs' list.
        for src in dep.direct_sources:
            if targets.get(src.path):
                continue
            proto = copy_proto(ctx, descriptor, src)
            targets[src] = proto
            protos.append(proto)

        # Iterate all transitive .proto files.  If we already processed in the
        # loop above, skip it. Otherwise add a copy action to get it into the
        # 'staging area'
        for src in dep.transitive_sources.to_list():
            if targets.get(src):
                continue
            if verbose > 2:
                print("transitive source: %r" % src)
            proto = copy_proto(ctx, descriptor, src)
            protos.append(proto)
            if ctx.attr.transitive:
                targets[src] = proto

    ###
    ### Part 3b: apply transitivity rules
    ###

    # If the 'transitive = true' was enabled, we collected all the protos into
    # the 'targets' list.
    # At this point we want to post-process that list and remove any protos that
    # might be incompatible with the plugin transitivity rules.
    if ctx.attr.transitive:
        for plugin in plugins:
            targets = _apply_plugin_transitivity_rules(ctx, targets, plugin)

    ###
    ### Part 3c: collect generated artifacts for all in the target list of protos to compile
    ###
    for src, proto in targets.items():
        for plugin in plugins:
            outputs = get_plugin_outputs(ctx, descriptor, outputs, src, proto, plugin)

    ###
    ### Part 4: build list of arguments for protoc
    ###

    args = ["--descriptor_set_out=%s" % descriptor.path]

    # By default we have a single 'proto_path' argument at the 'staging area'
    # root.
    args += ["--proto_path=%s" % outdir]

    if ctx.attr.include_imports:
        args += ["--include_imports"]

    if ctx.attr.include_source_info:
        args += ["--include_source_info"]

    for plugin in plugins:
        args += [get_plugin_out_arg(ctx, outdir, plugin, plugin_outfiles)]

    args += ["--plugin=protoc-gen-%s=%s" % (k, v.path) for k, v in plugin_tools.items()]

    args += [proto.path for proto in targets.values()]

    ###
    ### Part 5: build the final protoc command and declare the action
    ###

    mnemonic = "ProtoCompile"

    command = " ".join([protoc.path] + args)

    if verbose > 0:
        print("%s: %s" % (mnemonic, command))
    if verbose > 1:
        command += " && echo '\n##### SANDBOX AFTER RUNNING PROTOC' && find ."
    if verbose > 2:
        command = "echo '\n##### SANDBOX BEFORE RUNNING PROTOC' && find . && " + command
    if verbose > 3:
        command = "env && " + command
        for f in outputs:
            print("expected output: ", f.path)


    tools = [protoc] + plugin_tools.values()
    inputs = protos + data
    outs = outputs + [descriptor] + ctx.outputs.outputs

    if verbose > 3:
        for s in args:
            print("ARG: %s" % s)
        for k, f in targets.items():
            print("TARGET: %s=%s" % (k, f))
        for f in tools:
            print("TOOL: %s" % f.path)
        for f in inputs:
            print("INPUT: %s" % f.path)
        for f in outs:
            print("OUTPUT: %s" % f.path)

    ctx.actions.run_shell(
        mnemonic = mnemonic,
        command = command,
        inputs = inputs,
        outputs = outs,
        tools = tools,
    )

    ###
    ### Part 6: assemble output providers
    ###

    # The files for 'DefaultInfo' include any explicit outputs for the rule.  If
    # we are generating srcjars, use those as the final outputs rather than
    # their '.jar' intermediates.  Otherwise include all the file outputs.
    # NOTE: this looks a little wonky here.  It probably works in simple cases
    # where there list of plugins has length 1 OR all outputting to jars OR all
    # not outputting to jars.  Probably would break here if they were mixed.
    files = [] + ctx.outputs.outputs

    if len(srcjars) > 0:
        files += srcjars
    else:
        files += outputs
        if len(plugin_outfiles) > 0:
            files += plugin_outfiles.values()

    return [ProtoCompileInfo(
        label = ctx.label,
        plugins = plugins,
        protos = protos,
        outputs = outputs,
        files = files,
        tools = plugin_tools,
        args = args,
        descriptor = descriptor,
    ), DefaultInfo(files = depset(files))]


proto_compile = rule(
    implementation = proto_compile_impl,
    attrs = {
        "deps": attr.label_list(
            doc = "proto_library dependencies",
            mandatory = True,
            providers = [ProtoInfo],
        ),
        "plugins": attr.label_list(
            doc = "List of protoc plugins to apply",
            providers = [ProtoPluginInfo],
            mandatory = True,
        ),
        "plugin_options": attr.string_list(
            doc = "List of additional 'global' options to add (applies to all plugins)",
        ),
        "outputs": attr.output_list(
            doc = "Escape mechanism to explicitly declare files that will be generated",
        ),
        "protoc": attr.label(
            doc = "The protoc tool",
            default = "@com_google_protobuf//:protoc",
            cfg = "host",
            executable = True,
        ),
        "verbose": attr.int(
            doc = "Increase verbose level for more debugging",
        ),
        "include_imports": attr.bool(
            doc = "Pass the --include_imports argument to the protoc_plugin",
            default = True,
        ),
        "include_source_info": attr.bool(
            doc = "Pass the --include_source_info argument to the protoc_plugin",
            default = True,
        ),
        "transitive": attr.bool(
            doc = "Emit transitive artifacts",
        ),
        "transitivity": attr.string_dict(
            doc = "Transitive rules.  When the 'transitive' property is enabled, this string_dict can be used to exclude protos from the compilation list",
        ),
    },
    # TODO(pcj) remove this
    outputs = {
        "descriptor": "%{name}/descriptor.source.bin",
    },
    output_to_genfiles = True,
)