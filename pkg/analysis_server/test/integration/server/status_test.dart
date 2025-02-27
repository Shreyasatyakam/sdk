// Copyright (c) 2014, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

import 'dart:async';

import 'package:analysis_server/protocol/protocol_generated.dart';
import 'package:test/test.dart';
import 'package:test_reflective_loader/test_reflective_loader.dart';

import '../support/integration_tests.dart';

void main() {
  defineReflectiveSuite(() {
    defineReflectiveTests(StatusTest);
  });
}

@reflectiveTest
class StatusTest extends AbstractAnalysisServerIntegrationTest {
  Future<void> test_status() async {
    // After we kick off analysis, we should get one server.status message with
    // analyzing=true, and another server.status message after that with
    // analyzing=false.
    var analysisBegun = Completer();
    var analysisFinished = Completer();
    onServerStatus.listen((ServerStatusParams params) {
      var analysisStatus = params.analysis;
      if (analysisStatus != null) {
        if (analysisStatus.isAnalyzing) {
          expect(analysisBegun.isCompleted, isFalse);
          analysisBegun.complete();
        } else {
          expect(analysisFinished.isCompleted, isFalse);
          analysisFinished.complete();
        }
      }
    });
    writeFile(sourcePath('test.dart'), '''
void f() {
  var x;
}''');
    standardAnalysisSetup();
    expect(analysisBegun.isCompleted, isFalse);
    expect(analysisFinished.isCompleted, isFalse);
    await analysisBegun.future;

    expect(analysisFinished.isCompleted, isFalse);
    await analysisFinished.future;
  }
}
