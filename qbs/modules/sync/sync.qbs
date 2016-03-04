import qbs
import qbs.File
import qbs.FileInfo
import qbs.TextFile

// This is a qbs rewrite of syncqt.pl
Module {
    // Input
    property string module: ""
    property string prefix: "include"
    property var classNames: ({})
    readonly property var classFileNames: {
        var classFileNames = {};
        for (var i in classNames) {
            for (var j in classNames[i])
                classFileNames[classNames[i][j]] = i;
        }
        return classFileNames;
    }

    Rule {
        inputs: "hpp_syncable"
        outputFileTags: [
            "hpp_qpa", "hpp_private", "hpp_public", "hpp_forwarding", "hpp_module_input",
            "hpp_to_copy"
        ]
        outputArtifacts: {
            var module = product.moduleProperty("sync", "module");
            var basePath = FileInfo.joinPaths(project.buildDirectory,
                                              product.moduleProperty("sync", "prefix"), module);

            // Simply copy private headers without parsing
            var version = project.version;
            if ((module == "QtGui" && (input.fileName.startsWith("qplatform")
                || input.fileName.startsWith("qwindowsysteminterface")))
                    || (module == "QtPrintSupport" && input.fileName.startsWith("qplatform"))) {
                return [{
                    filePath: FileInfo.joinPaths(basePath, version, module, "qpa", input.fileName),
                    fileTags: ["hpp_qpa", "hpp_to_copy"]
                }];
            }

            if (input.fileName.endsWith("_p.h")) {
                return [{
                    filePath: FileInfo.joinPaths(basePath, version, module, "private",
                                                 input.fileName),
                    fileTags: ["hpp_private", "hpp_to_copy"]
                }];
            }

            // regular expressions used in parsing
            var reFwdDecl = /^(class|struct) +(\w+);$/;
            var reTypedefFn = /^typedef *.*\(\*(Q[^\)]*)\)\(.*\);$/;
            var reTypedef = /^typedef +(unsigned )?([^ ]*)(<[\w, ]+>)? +(Q[^ ]*);$/;
            var reQtMacro = / ?Q_[A-Z_]+/;
            var reDecl = /^(template <class [\w, ]+> )?(class|struct) +(\w+)( ?: public [\w<>, ]+)?( {)?$/;
            var reIterator = /^Q_DECLARE_\w+ITERATOR\((\w+)\)$/;
            var reNamespace = /^namespace \w+( {)?/; //extern "C" could go here too

            var classes = [];
            var excludeFromModuleInclude
                    = input.fileName.contains("_") || input.fileName.contains("qconfig");

            var insideQt = false;

            var file = new TextFile(input.filePath, TextFile.ReadOnly);
            var line = "";
            var braceDepth = 0;
            var namespaceDepth = -1;
            var lineCount = 0; // for debugging
            while (!file.atEof()) {
                if (!line.length) {
                    line = file.readLine();
                    ++lineCount;
                }

                // Remove C comments ### allow starting within a line
                if (line.startsWith("/*")) {
                    while (!file.atEof()) {
                        var commentEnd = line.indexOf("*/");
                        if (commentEnd >= 0) {
                            line = line.substring(commentEnd + 2);
                            break;
                        }
                        line = file.readLine();
                        ++lineCount;
                    }
                    continue;
                }

                // remove C++ comments
                line = line.replace(/ +\/\/.*$/, '');
                if (line.length == 0)
                    continue;

                if (line.startsWith("#")) {
                    if (line == "#pragma qt_sync_stop_processing")
                        break;

                    if (line == "#pragma qt_no_master_include") {
                        excludeFromModuleInclude = true;
                        line = "";
                        continue;
                    }

                    if (/#pragma qt_class\(([^)]*)\)$/.test(line)) {
                        classes.push(line.match(/#pragma qt_class\(([^)]*)\)$/)[1]);
                        line = "";
                        continue;
                    }

                    // Drop remaining preprocessor commands
                    while (!file.atEof()) {
                        if (line.endsWith("\\")) {
                            line = file.readLine();
                            ++lineCount;
                            continue;
                        }
                        line = "";
                        break;
                    }
                    continue;
                }

                // Track brace depth
                var openingBraces = line.match(/\{/g) || [];
                var closingBraces = line.match(/\}/g) || [];
                braceDepth += openingBraces.length - closingBraces.length;
                if (braceDepth < 0)
                    throw "Error in parsing header " + input.filePath + ", line " + lineCount + ": brace depth fell below 0.";

                // We only are interested in classes inside the namespace
                if (line == "QT_BEGIN_NAMESPACE") {
                    insideQt = true;
                    line = "";
                    continue;
                }

                if (!insideQt) {
                    line = "";
                    continue;
                }

                // Ignore internal namespaces
                if (namespaceDepth >= 0 && braceDepth >= namespaceDepth) {
                    line = "";
                    continue;
                }

                if (reNamespace.test(line)) {
                    namespaceDepth = braceDepth;
                    if (!line.endsWith("{"))
                        namespaceDepth += 1;
                    line = "";
                    continue;
                } else {
                    namespaceDepth = -1;
                }

                if (line == "QT_END_NAMESPACE") {
                    insideQt = false;
                    line = "";
                    continue;
                }

                // grab iterators
                if (reIterator.test(line)) {
                    var className = "Q";
                    if (line.contains("MUTABLE"))
                        className += "Mutable";
                    className += line.match(reIterator)[1] + "Iterator";
                    classes.push(className);
                    line = "";
                    continue;
                }

                // make parsing easier by removing noise
                line = line.replace(reQtMacro, "");

                // ignore forward declarations ### decide if this is needed (that is, if is really a false positive)
                if (reFwdDecl.test(line)) {
                    line = "";
                    continue;
                }

                // accept typedefs
                if (reTypedefFn.test(line)) {
                    classes.push(line.match(reTypedefFn)[1]);
                    line = "";
                    continue;
                }

                if (reTypedef.test(line)) {
                    classes.push(line.match(reTypedef)[4]);
                    line = "";
                    continue;
                }

                // grab classes
                if (reDecl.test(line)) {
                    classes.push(line.match(reDecl)[3]);
                    line = "";
                    continue;
                }

                line = "";
            }
            file.close();

            var artifacts = [];
            var classFileNames = product.moduleProperty("sync", "classFileNames");
            for (var i in classes) {
                if (classes[i] in classFileNames)
                    continue; // skip explicitly defined classes (and handle them below)
                artifacts.push({
                    filePath: FileInfo.joinPaths(basePath, classes[i]),
                    fileTags: ["hpp_forwarding"]
                });
            }

            var classNames = product.moduleProperty("sync", "classNames");
            if (input.fileName in classNames) {
                for (var i in classNames[input.fileName]) {
                    artifacts.push({
                        filePath: FileInfo.joinPaths(basePath, classNames[input.fileName][i]),
                        fileTags: ["hpp_forwarding"]
                    });
                }
            }

            var fileTags = ["hpp_public", "hpp_to_copy"];
            if (!excludeFromModuleInclude)
                fileTags.push("hpp_module_input");
            artifacts.push({
                filePath: FileInfo.joinPaths(basePath, input.fileName),
                fileTags: fileTags
            });

            return artifacts;
        }

        prepare: {
            var cmd = new JavaScriptCommand();
            cmd.description = "syncing " + input.fileName;
            cmd.developerBuild = product.moduleProperty("configure", "private_tests");
            cmd.sourceCode = function() {
                for (var i in outputs.hpp_to_copy) {
                    var header = outputs.hpp_to_copy[i];
                    if (developerBuild) {
                        var file = new TextFile(header.filePath, TextFile.WriteOnly);
                        file.writeLine("#include \"" + input.filePath + "\"");
                        file.close();
                    } else {
                        File.copy(input.filePath, header.filePath);
                    }
                }
                for (i in outputs.hpp_forwarding) {
                    var header = outputs.hpp_forwarding[i];
                    var file = new TextFile(header.filePath, TextFile.WriteOnly);
                    file.writeLine("#include \"" +
                                   (developerBuild ? input.filePath : input.fileName) + "\"");
                    file.close();
                }
            };
            return cmd;
        }
    }

    Rule {
        inputsFromDependencies: ["hpp_module"]
        multiplex: true
        Artifact {
            filePath: {
                var module = product.moduleProperty("sync", "module");
                return FileInfo.joinPaths(project.buildDirectory,
                                          product.moduleProperty("sync", "prefix"), module,
                                          module + "Depends");
            }
            fileTags: ["hpp_depends"]
        }
        prepare: {
            var cmd = new JavaScriptCommand();
            cmd.description = "Creating dependency header " + output.fileName;
            cmd.sourceCode = function() {
                var file = new TextFile(output.filePath, TextFile.WriteOnly);
                file.writeLine("#ifdef __cplusplus /* create empty PCH in C mode */");
                for (var i = 0; i < inputs.hpp_module.length; ++i) {
                    var fileName = inputs.hpp_module[i].fileName;
                    file.writeLine('#include <' + fileName + '/' + fileName + '>');
                }
                file.writeLine("#endif");
                file.close();
            };
            return [cmd];
        }
    }

    Rule {
        // TODO: I have observed this rule getting run twice per product during one build. How is that possible?
        inputs: ["hpp_module_input", "hpp_depends"]
        multiplex: true
        Artifact {
            filePath: {
                var module = product.moduleProperty("sync", "module");
                return FileInfo.joinPaths(project.buildDirectory,
                                          product.moduleProperty("sync", "prefix"), module, module);
            }
            fileTags: ["hpp_module"]
        }
        prepare: {
            var cmd = new JavaScriptCommand();
            cmd.description = "creating module header " + output.fileName;
            cmd.module = product.moduleProperty("sync", "module");
            cmd.sourceCode = function() {
                var file = new TextFile(output.filePath, TextFile.WriteOnly);
                file.writeLine("#ifndef QT_" + module.toUpperCase() + "_MODULE_H");
                file.writeLine("#define QT_" + module.toUpperCase() + "_MODULE_H");
                if (inputs.hpp_depends)
                    file.writeLine("#include <" + module + '/' + module + "Depends>");
                var inputHeaders = inputs["hpp_module_input"] || [];
                inputHeaders.forEach(function(header) {
                    file.writeLine('#include "' + header.fileName + '"');
                });
                file.writeLine("#endif");
                file.close();
            };
            return cmd;
        }
    }
}
