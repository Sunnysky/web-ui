// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/**
 * Tests that we are generating a valid `dart:html` type for each element
 * field. This test is a bit goofy because it needs to run the `dart_analyzer`,
 * but I can't think of an easier way to validate that the HTML types in our
 * table exist.
 */
library html_type_test;

import 'dart:io';
import 'package:html5lib/dom.dart';
import 'package:pathos/path.dart' as path;
import 'package:unittest/compact_vm_config.dart';
import 'package:unittest/unittest.dart';
import 'package:web_ui/src/html5_setters.g.dart';
import 'package:web_ui/src/html5_utils.dart';

import 'testing.dart';

main() {
  useCompactVMConfiguration();
  var dir = path.join(
      path.absolute(path.dirname(new Options().script)), 'data', 'output');

  test('generate type test for tag -> element mapping', () {
    var code = new StringBuffer();
    code.write('import "dart:html" as html;\n');
    htmlElementNames.forEach((tag, className) {
      code.write('html.$className _$tag;\n');
    });

    // Note: name is important for this to get picked up by run.sh
    // We don't analyze here, but run.sh will analyze it.
    new File(path.join(dir, 'html5_utils_test_tag_bootstrap.dart'))
        .writeAsStringSync(code.toString());
  });

  test('generate type test for attribute -> field mapping', () {
    var code = new StringBuffer();
    code.write('import "dart:html" as html;\n');
    code.write('main() {\n');

    var allTags = htmlElementNames.keys;
    htmlElementFields.forEach((type, attrToField) {
      var id = type.replaceAll('.', '_');
      code.write('  html.$type _$id = null;\n');
      for (var field in attrToField.values) {
        code.write('_$id.$field = null;\n');
      }
    });
    code.write('}\n');

    // Note: name is important for this to get picked up by run.sh
    // We don't analyze here, but run.sh will analyze it.
    new File(path.join(dir, 'html5_utils_test_attr_bootstrap.dart'))
        .writeAsStringSync(code.toString());
  });
}
