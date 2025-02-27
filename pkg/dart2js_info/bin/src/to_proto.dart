// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// @dart = 2.11

/// Command-line tool to convert an info.json file ouputted by dart2js to the
/// alternative protobuf format.

import 'dart:io';

import 'package:args/command_runner.dart';

import 'package:dart2js_info/proto_info_codec.dart';
import 'package:dart2js_info/src/io.dart';

import 'inject_text.dart';
import 'usage_exception.dart';

/// Converts a dump-info file emitted by dart2js to the proto format
class ToProtoCommand extends Command<void> with PrintUsageException {
  @override
  final String name = "to_proto";
  @override
  final String description = "Convert any info file to proto format.";

  @override
  void run() async {
    if (argResults.rest.isEmpty) {
      usageException('Missing argument: <input-info>');
    }

    String filename = argResults.rest[0];
    final info = await infoFromFile(filename);
    if (argResults['inject-text']) injectText(info);
    final proto = AllInfoProtoCodec().encode(info);
    String outputFilename = argResults['out'] ?? '$filename.pb';
    final outputFile = File(outputFilename);
    await outputFile.writeAsBytes(proto.writeToBuffer(), mode: FileMode.write);
  }
}
