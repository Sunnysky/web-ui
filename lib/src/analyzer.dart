// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

/**
 * Part of the template compilation that concerns with extracting information
 * from the HTML parse tree.
 */
library analyzer;

import 'dart:uri';
import 'package:html5lib/dom.dart';
import 'package:html5lib/dom_parsing.dart';
import 'package:source_maps/span.dart';
import 'package:pathos/path.dart' as path;

import 'dart_parser.dart';
import 'files.dart';
import 'html5_utils.dart';
import 'info.dart';
import 'messages.dart';
import 'summary.dart';
import 'utils.dart';

/**
 * Finds custom elements in this file and the list of referenced files with
 * component declarations. This is the first pass of analysis on a file.
 *
 * Adds emitted error/warning messages to [messages], if [messages] is
 * supplied.
 */
FileInfo analyzeDefinitions(SourceFile file, String packageRoot,
    Messages messages, {bool isEntryPoint: false}) {
  var result = new FileInfo(file.path, isEntryPoint);
  var loader = new _ElementLoader(result, packageRoot, messages);
  loader.visit(file.document);
  return result;
}

/**
 * Extract relevant information from [source] and it's children.
 * Used for testing.
 *
 * Adds emitted error/warning messages to [messages], if [messages] is
 * supplied.
 */
FileInfo analyzeNodeForTesting(Node source, Messages messages,
    {String filepath: 'mock_testing_file.html'}) {
  var result = new FileInfo(filepath);
  new _Analyzer(result, new IntIterator(), messages).visit(source);
  return result;
}

/**
 *  Extract relevant information from all files found from the root document.
 *
 *  Adds emitted error/warning messages to [messages], if [messages] is
 *  supplied.
 */
void analyzeFile(SourceFile file, Map<String, FileInfo> info,
    Iterator<int> uniqueIds, Messages messages) {
  var fileInfo = info[file.path];
  var analyzer = new _Analyzer(fileInfo, uniqueIds, messages);
  analyzer._normalize(fileInfo, info);
  analyzer.visit(file.document);
}


/** A visitor that walks the HTML to extract all the relevant information. */
class _Analyzer extends TreeVisitor {
  final FileInfo _fileInfo;
  LibraryInfo _currentInfo;
  ElementInfo _parent;
  Iterator<int> _uniqueIds;
  Messages _messages;

  /**
   * Whether to keep indentation spaces. Break lines and indentation spaces
   * within templates are preserved in HTML. When users specify the attribute
   * 'indentation="remove"' on a template tag, we'll trim those indentation
   * spaces that occur within that tag and its decendants. If any decendant
   * specifies 'indentation="preserve"', then we'll switch back to the normal
   * behavior.
   */
  bool _keepIndentationSpaces = true;

  /**
   * Adds emitted error/warning messages to [_messages].
   * [_messages] must not be null.
   */
  _Analyzer(this._fileInfo, this._uniqueIds, this._messages) {
    assert(this._messages != null);
    _currentInfo = _fileInfo;
  }

  void visitElement(Element node) {
    var info = null;
    if (node.tagName == 'script') {
      // We already extracted script tags in previous phase.
      return;
    }

    if (node.tagName == 'template'
        || node.attributes.containsKey('template')
        || node.attributes.containsKey('if')
        || node.attributes.containsKey('instantiate')
        || node.attributes.containsKey('iterate')) {
      // template tags, conditionals and iteration are handled specially.
      info = _createTemplateInfo(node);
    }

    // TODO(jmesserly): it would be nice not to create infos for text or
    // elements that don't need data binding. Ideally, we would visit our
    // child nodes and get their infos, and if any of them need data binding,
    // we create an ElementInfo for ourselves and return it, otherwise we just
    // return null.
    if (info == null) {
      // <element> tags are tracked in the file's declared components, so they
      // don't need a parent.
      var parent = node.tagName == 'element' ? null : _parent;
      info = new ElementInfo(node, parent);
    }

    visitElementInfo(info);

    if (_parent == null) {
      _fileInfo.bodyInfo = info;
    }
  }

  void visitElementInfo(ElementInfo info) {
    var node = info.node;

    if (node.id != '') info.identifier = '__${toCamelCase(node.id)}';
    if (node.tagName == 'body' || (_currentInfo is ComponentInfo
          && (_currentInfo as ComponentInfo).template == node)) {
      info.isRoot = true;
      info.identifier = '_root';
    }

    _bindCustomElement(node, info);

    var lastInfo = _currentInfo;
    if (node.tagName == 'element') {
      // If element is invalid _ElementLoader already reported an error, but
      // we skip the body of the element here.
      var name = node.attributes['name'];
      if (name == null) return;

      ComponentInfo component = _fileInfo.components[name];
      if (component == null) return;

      // Associate ElementInfo of the <element> tag with its component.
      component.elemInfo = info;

      _analyzeComponent(component);

      _currentInfo = component;
    }

    node.attributes.forEach((k, v) => visitAttribute(info, k, v));

    var savedParent = _parent;
    _parent = info;
    var keepSpaces = _keepIndentationSpaces;
    if (node.tagName == 'template' &&
        node.attributes.containsKey('indentation')) {
      var value = node.attributes['indentation'];
      if (value != 'remove' && value != 'preserve') {
        _messages.warning(
            "Invalid value for 'indentation' ($value). By default we preserve "
            "the indentation. Valid values are either 'remove' or 'preserve'.",
            node.sourceSpan, file: _fileInfo.inputPath);
      }
      _keepIndentationSpaces = value != 'remove';
    }

    // Invoke super to visit children.
    super.visitElement(node);

    _keepIndentationSpaces = keepSpaces;
    _currentInfo = lastInfo;
    _parent = savedParent;

    if (_needsIdentifier(info)) {
      _ensureParentHasQuery(info);
      if (info.identifier == null) {
        _uniqueIds.moveNext();
        var id = '__e-${_uniqueIds.current}';
        info.identifier = toCamelCase(id);
        // If it's not created in code, we'll query the element by it's id.
        if (!info.createdInCode) node.attributes['id'] = id;
      }
    }
  }

  /**
   * If this [info] is not created in code, ensure that whichever parent element
   * is created in code has been marked appropriately, so we get an identifier.
   */
  static void _ensureParentHasQuery(ElementInfo info) {
    if (info.isRoot || info.createdInCode) return;

    for (var p = info.parent; p != null; p = p.parent) {
      if (p.createdInCode) {
        p.hasQuery = true;
        return;
      }
    }
  }

  /**
   * Whether code generators need to create a field to store a reference to this
   * element. This is typically true whenever we need to access the element
   * (e.g. to add event listeners, update values on data-bound watchers, etc).
   */
  static bool _needsIdentifier(ElementInfo info) {
    if (info.isRoot) return false;

    return info.hasDataBinding || info.hasIfCondition || info.hasIterate
       || info.hasQuery || info.component != null || info.values.length > 0 ||
       info.events.length > 0;
  }

  void _analyzeComponent(ComponentInfo component) {
    component.extendsComponent = _fileInfo.components[component.extendsTag];
    if (component.extendsComponent == null &&
        isCustomTag(component.extendsTag)) {
      _messages.warning(
          'custom element with tag name ${component.extendsTag} not found.',
          component.element.sourceSpan, file: _fileInfo.inputPath);
    }

    // Now that the component's code has been loaded, we can validate that the
    // class exists.
    component.findClassDeclaration(_messages);
  }

  void _bindCustomElement(Element node, ElementInfo info) {
    // <fancy-button>
    var component = _fileInfo.components[node.tagName];
    if (component == null) {
      // TODO(jmesserly): warn for unknown element tags?

      // <button is="fancy-button">
      var componentName = node.attributes['is'];
      if (componentName != null) {
        component = _fileInfo.components[componentName];
      } else if (isCustomTag(node.tagName)) {
        componentName = node.tagName;
      }
      if (component == null && componentName != null) {
        _messages.warning(
            'custom element with tag name $componentName not found.',
            node.sourceSpan, file: _fileInfo.inputPath);
      }
    }

    if (component != null && !component.hasConflict) {
      info.component = component;
      _currentInfo.usedComponents[component] = true;
    }
  }

  TemplateInfo _createTemplateInfo(Element node) {
    if (node.tagName != 'template' &&
        !node.attributes.containsKey('template')) {
      _messages.warning('template attribute is required when using if, '
          'instantiate, or iterate attributes.',
          node.sourceSpan, file: _fileInfo.inputPath);
    }

    var instantiate = node.attributes['instantiate'];
    var condition = node.attributes['if'];
    if (instantiate != null) {
      if (instantiate.startsWith('if ')) {
        if (condition != null) {
          _messages.warning(
              'another condition was already defined on this element.',
              node.sourceSpan, file: _fileInfo.inputPath);
        } else {
          condition = instantiate.substring(3);
        }
      }
    }
    var iterate = node.attributes['iterate'];

    // Note: we issue warnings instead of errors because the spirit of HTML and
    // Dart is to be forgiving.
    if (condition != null && iterate != null) {
      _messages.warning('template cannot have both iteration and conditional '
          'attributes', node.sourceSpan, file: _fileInfo.inputPath);
      return null;
    }

    if (node.parent != null && node.parent.tagName == 'element' &&
        (condition != null || iterate != null)) {

      // TODO(jmesserly): would be cool if we could just refactor this, or offer
      // a quick fix in the Editor.
      var example = new Element.html('<element><template><template>');
      node.parent.attributes.forEach((k, v) { example.attributes[k] = v; });
      var nestedTemplate = example.nodes.first.nodes.first;
      node.attributes.forEach((k, v) { nestedTemplate.attributes[k] = v; });

      _messages.warning('the <template> of a custom element does not support '
          '"if" or "iterate". However, you can create another template node '
          'that is a child node, for example:\n'
          '${example.outerHtml}',
          node.parent.sourceSpan, file: _fileInfo.inputPath);
      return null;
    }

    if (condition != null) {
      var result = new TemplateInfo(node, _parent, ifCondition: condition);
      result.removeAttributes.add('if');
      result.removeAttributes.add('instantiate');
      if (node.tagName == 'template') {
        return node.nodes.length > 0 ? result : null;
      }

      result.removeAttributes.add('template');


      // TODO(jmesserly): if-conditions in attributes require injecting a
      // placeholder node, and a real node which is a clone. We should
      // consider a design where we show/hide the node instead (with care
      // taken not to evaluate hidden bindings). That is more along the lines
      // of AngularJS, and would have a cleaner DOM. See issue #142.
      var contentNode = node.clone();
      // Clear out the original attributes. This is nice to have, but
      // necessary for ID because of issue #141.
      node.attributes.clear();
      contentNode.nodes.addAll(node.nodes);

      // Create a new ElementInfo that is a child of "result" -- the
      // placeholder node. This will become result.contentInfo.
      visitElementInfo(new ElementInfo(contentNode, result));
      return result;
    } else if (iterate != null) {
      var match = new RegExp(r"(.*) in (.*)").firstMatch(iterate);
      if (match != null) {
        if (node.nodes.length == 0) return null;
        var result = new TemplateInfo(node, _parent, loopVariable: match[1],
            loopItems: match[2]);
        result.removeAttributes.add('iterate');
        if (node.tagName != 'template') result.removeAttributes.add('template');
        return result;
      }
      _messages.warning('template iterate must be of the form: '
          'iterate="variable in list", where "variable" is your variable name '
          'and "list" is the list of items.',
          node.sourceSpan, file: _fileInfo.inputPath);
    }
    return null;
  }

  void visitAttribute(ElementInfo info, String name, String value) {
    if (name.startsWith('on')) {
      _readEventHandler(info, name, value);
      return;
    } else if (name.startsWith('bind-')) {
      // Strip leading "bind-" and make camel case.
      var fieldName = toCamelCase(name.substring(5));
      if (_readTwoWayBinding(info, fieldName, value)) {
        info.removeAttributes.add(name);
      }
      return;
    }

    AttributeInfo attrInfo;
    if (name == 'style') {
      attrInfo = _readStyleAttribute(info, value);
    } else if (name == 'class') {
      attrInfo = _readClassAttribute(info, value);
    } else {
      attrInfo = _readAttribute(info, name, value);
    }

    if (attrInfo != null) {
      info.attributes[name] = attrInfo;
      info.hasDataBinding = true;
    }
  }

  /**
   * Support for inline event handlers that take expressions.
   * For example: `on-double-click=myHandler($event, todo)`.
   */
  void _readEventHandler(ElementInfo info, String name, String value) {
    if (!name.startsWith('on-')) {
      // TODO(jmesserly): do we need an option to suppress this warning?
      _messages.warning('Event handler $name will be interpreted as an inline '
          'JavaScript event handler. Use the form '
          'on-event-name="handlerName(\$event)" if you want a Dart handler '
          'that will automatically update the UI based on model changes.',
          info.node.sourceSpan, file: _fileInfo.inputPath);
      return;
    }

    _addEvent(info, toCamelCase(name), (elem) => value);
    info.removeAttributes.add(name);
  }

  EventInfo _addEvent(ElementInfo info, String name, ActionDefinition action) {
    var events = info.events.putIfAbsent(name, () => <EventInfo>[]);
    var eventInfo = new EventInfo(name, action);
    events.add(eventInfo);
    return eventInfo;
  }

  // http://dev.w3.org/html5/spec/the-input-element.html#the-input-element
  /** Support for two-way bindings. */
  bool _readTwoWayBinding(ElementInfo info, String name, String value) {
    var elem = info.node;
    var binding = new BindingInfo.fromText(value);

    // Find the HTML tag name.
    var isInput = info.baseTagName == 'input';
    var isTextArea = info.baseTagName == 'textarea';
    var isSelect = info.baseTagName == 'select';
    var inputType = elem.attributes['type'];

    String eventStream;

    // Special two-way binding logic for input elements.
    if (isInput && name == 'checked') {
      if (inputType == 'radio') {
        if (!_isValidRadioButton(info)) return false;
      } else if (inputType != 'checkbox') {
        _messages.error('checked is only supported in HTML with type="radio" '
            'or type="checked".', info.node.sourceSpan,
            file: _fileInfo.inputPath);
        return false;
      }

      // Both 'click' and 'change' seem reliable on all the modern browsers.
      eventStream = 'onChange';
    } else if (isSelect && (name == 'selectedIndex' || name == 'value')) {
      eventStream = 'onChange';
    } else if (isInput && name == 'value' && inputType == 'radio') {
      return _addRadioValueBinding(info, binding);
    } else if (isTextArea && name == 'value' || isInput &&
        (name == 'value' || name == 'valueAsDate' || name == 'valueAsNumber')) {
      // Input event is fired more frequently than "change" on some browsers.
      // We want to update the value for each keystroke.
      eventStream = 'onInput';
    } else if (info.component != null) {
      // Assume we are binding a field on the component.
      // TODO(jmesserly): validate this assumption about the user's code by
      // using compile time mirrors.

      _checkDuplicateAttribute(info, name);
      info.attributes[name] = new AttributeInfo([binding],
          customTwoWayBinding: true);
      info.hasDataBinding = true;
      return true;

    } else {
      _messages.error('Unknown two-way binding attribute $name. Ignored.',
          info.node.sourceSpan, file: _fileInfo.inputPath);
      return false;
    }

    _checkDuplicateAttribute(info, name);

    info.attributes[name] = new AttributeInfo([binding]);
    _addEvent(info, eventStream, (e) => '${binding.exp} = $e.$name');
    info.hasDataBinding = true;
    return true;
  }

  void _checkDuplicateAttribute(ElementInfo info, String name) {
    if (info.node.attributes[name] != null) {
      _messages.warning('Duplicate attribute $name. You should provide either '
          'the two-way binding or the attribute itself. The attribute will be '
          'ignored.', info.node.sourceSpan, file: _fileInfo.inputPath);
      info.removeAttributes.add(name);
    }
  }

  bool _isValidRadioButton(ElementInfo info) {
    if (info.attributes['checked'] == null) return true;

    _messages.error('Radio buttons cannot have both "checked" and "value" '
        'two-way bindings. Either use checked:\n'
        '  <input type="radio" bind-checked="myBooleanVar">\n'
        'or value:\n'
        '  <input type="radio" bind-value="myStringVar" value="theValue">',
        info.node.sourceSpan, file: _fileInfo.inputPath);
    return false;
  }

  /**
   * Radio buttons use the "value" and "bind-value" fields.
   * The "value" attribute is assigned to the binding expression when checked,
   * and the checked field is updated if "value" matches the binding expression.
   */
  bool _addRadioValueBinding(ElementInfo info, BindingInfo binding) {
    if (!_isValidRadioButton(info)) return false;

    // TODO(jmesserly): should we read the element's "value" at runtime?
    var radioValue = info.node.attributes['value'];
    if (radioValue == null) {
      _messages.error('Radio button bindings need "bind-value" and "value".'
          'For example: '
          '<input type="radio" bind-value="myStringVar" value="theValue">',
          info.node.sourceSpan, file: _fileInfo.inputPath);
      return false;
    }

    radioValue = escapeDartString(radioValue);
    info.attributes['checked'] = new AttributeInfo(
        [new BindingInfo("${binding.exp} == '$radioValue'", false)]);
    _addEvent(info, 'onChange', (e) => "${binding.exp} = '$radioValue'");
    info.hasDataBinding = true;
    return true;
  }

  /**
   * Data binding support in attributes. Supports multiple bindings.
   * This is can be used for any attribute, but a typical use case would be
   * URLs, for example:
   *
   *       href="#{item.href}"
   */
  AttributeInfo _readAttribute(ElementInfo info, String name, String value) {
    var parser = new BindingParser(value);
    if (!parser.moveNext()) {
      if (info.component == null || globalAttributes.contains(name) ||
          name == 'is') {
        return null;
      }
      return new AttributeInfo([], textContent: [parser.textContent]);
    }

    info.removeAttributes.add(name);
    var bindings = <BindingInfo>[];
    var content = <String>[];
    parser.readAll(bindings, content);

    // Use a simple attriubte binding if we can.
    // This kind of binding works for non-String values.
    if (bindings.length == 1 && content[0] == '' && content[1] == '') {
      return new AttributeInfo(bindings);
    }

    // Otherwise do a text attribute that performs string interpolation.
    return new AttributeInfo(bindings, textContent: content);
  }

  /**
   * Special support to bind style properties of the forms:
   *     style="{{mapValue}}"
   *     style="property: {{value1}}; other-property: {{value2}}"
   */
  AttributeInfo _readStyleAttribute(ElementInfo info, String value) {
    var parser = new BindingParser(value);
    if (!parser.moveNext()) return null;

    var bindings = <BindingInfo>[];
    var content = <String>[];
    parser.readAll(bindings, content);

    // Use a style attribute binding if we can.
    // This kind of binding works for map values.
    if (bindings.length == 1 && content[0] == '' && content[1] == '') {
      return new AttributeInfo(bindings, isStyle: true);
    }

    // Otherwise do a text attribute that performs string interpolation.
    return new AttributeInfo(bindings, textContent: content);
  }

  /**
   * Special support to bind each css class separately in attributes of the
   * form:
   *     class="{{class1}} class2 {{class3}} {{class4}}"
   */
  AttributeInfo _readClassAttribute(ElementInfo info, String value) {
    var parser = new BindingParser(value);
    if (!parser.moveNext()) return null;

    var bindings = <BindingInfo>[];
    var content = <String>[];
    parser.readAll(bindings, content);

    // Update class attributes to only have non-databound class names for
    // attributes for the HTML.
    info.node.attributes['class'] = content.join('');

    return new AttributeInfo(bindings, isClass: true);
  }

  void visitText(Text text) {
    var parser = new BindingParser(text.value);
    if (!parser.moveNext()) {
      if (!_keepIndentationSpaces) {
        text.value = trimOrCompact(text.value);
      }
      if (text.value != '') new TextInfo(text, _parent);
      return;
    }

    _parent.hasDataBinding = true;
    _parent.childrenCreatedInCode = true;

    // We split [text] so that each binding has its own text node.
    var node = text.parent;
    do {
      _addRawTextContent(parser.textContent);
      var placeholder = new Text('');
      _uniqueIds.moveNext();
      var id = '__binding${_uniqueIds.current}';
      new TextInfo(placeholder, _parent, parser.binding, id);
    } while (parser.moveNext());

    _addRawTextContent(parser.textContent);
  }

  void _addRawTextContent(String content) {
    if (!_keepIndentationSpaces) {
      content = trimOrCompact(content);
    }
    if (content != '') {
      new TextInfo(new Text(content), _parent);
    }
  }

  /**
   * Normalizes references in [info]. On the [analyzeDefinitions] phase, the
   * analyzer extracted names of files and components. Here we link those names
   * to actual info classes. In particular:
   *   * we initialize the [components] map in [info] by importing all
   *     [declaredComponents],
   *   * we scan all [componentLinks] and import their [declaredComponents],
   *     using [files] to map the href to the file info. Names in [info] will
   *     shadow names from imported files.
   *   * we fill [externalCode] on each component declared in [info].
   */
  void _normalize(FileInfo info, Map<String, FileInfo> files) {
    _attachExtenalScript(info, files);

    for (var component in info.declaredComponents) {
      _addComponent(info, component);
      _attachExtenalScript(component, files);
    }

    for (var link in info.componentLinks) {
      var file = files[link];
      // We already issued an error for missing files.
      if (file == null) continue;
      file.declaredComponents.forEach((c) => _addComponent(info, c));
    }
  }

  /**
   * Stores a direct reference in [info] to a dart source file that was loaded
   * in a script tag with the 'src' attribute.
   */
  void _attachExtenalScript(LibraryInfo info, Map<String, FileInfo> files) {
    var filePath = info.externalFile;
    if (filePath != null) {
      info.externalCode = files[filePath];
      if (info.externalCode != null) info.externalCode.htmlFile = info;
    }
  }

  /** Adds a component's tag name to the names in scope for [fileInfo]. */
  void _addComponent(FileInfo fileInfo, ComponentSummary component) {
    var existing = fileInfo.components[component.tagName];
    if (existing != null) {
      if (existing == component) {
        // This is the same exact component as the existing one.
        return;
      }

      if (existing is ComponentInfo && component is! ComponentInfo) {
        // Components declared in [fileInfo] shadow component names declared in
        // imported files.
        return;
      }

      if (existing.hasConflict) {
        // No need to report a second error for the same name.
        return;
      }

      existing.hasConflict = true;

      if (component is ComponentInfo) {
        _messages.error('duplicate custom element definition for '
            '"${component.tagName}".', existing.sourceSpan);
        _messages.error('duplicate custom element definition for '
            '"${component.tagName}" (second location).', component.sourceSpan);
      } else {
        _messages.error('imported duplicate custom element definitions '
            'for "${component.tagName}".', existing.sourceSpan);
        _messages.error('imported duplicate custom element definitions '
            'for "${component.tagName}" (second location).',
            component.sourceSpan);
      }
    } else {
      fileInfo.components[component.tagName] = component;
    }
  }
}

/** A visitor that finds `<link rel="components">` and `<element>` tags.  */
class _ElementLoader extends TreeVisitor {
  final FileInfo _fileInfo;
  LibraryInfo _currentInfo;
  String _packageRoot;
  bool _inHead = false;
  Messages _messages;

  /**
   * Adds emitted warning/error messages to [_messages]. [_messages]
   * must not be null.
   */
  _ElementLoader(this._fileInfo, this._packageRoot, this._messages) {
    assert(this._messages != null);
    _currentInfo = _fileInfo;
  }

  void visitElement(Element node) {
    switch (node.tagName) {
      case 'link': visitLinkElement(node); break;
      case 'element': visitElementElement(node); break;
      case 'script': visitScriptElement(node); break;
      case 'head':
        var savedInHead = _inHead;
        _inHead = true;
        super.visitElement(node);
        _inHead = savedInHead;
        break;
      default: super.visitElement(node); break;
    }
  }

  /**
   * Process `link rel="component"` as specified in:
   * <https://dvcs.w3.org/hg/webcomponents/raw-file/tip/spec/components/index.html#link-type-component>
   */
  void visitLinkElement(Element node) {
    var rel = node.attributes['rel'];
    // TODO(jmesserly): deprecate the plural form, it is singular in the spec.
    if (rel != 'component' && rel != 'components' &&
        rel != 'stylesheet') return;

    if (!_inHead) {
      _messages.warning('link rel="$rel" only valid in '
          'head.', node.sourceSpan, file: _fileInfo.inputPath);
      return;
    }

    var href = node.attributes['href'];
    if (href == null || href == '') {
      _messages.warning('link rel="$rel" missing href.',
          node.sourceSpan, file: _fileInfo.inputPath);
      return;
    }

    if (rel == 'stylesheet') {
      var uri = Uri.parse(href);
      if (uri.domain != '') return;
      if (uri.scheme != '' && uri.scheme != 'package') return;
    }

    var hrefTarget;
    if (href.startsWith('package:')) {
      hrefTarget = path.join(_packageRoot, href.substring(8));
    } else if (path.isAbsolute(href)) {
      hrefTarget = href;
    } else {
      hrefTarget = path.join(path.dirname(_fileInfo.inputPath), href);
    }
    hrefTarget = path.normalize(hrefTarget);

    if (rel == 'stylesheet') {
      _fileInfo.styleSheetHref.add(hrefTarget);
    } else {
      _fileInfo.componentLinks.add(hrefTarget);
    }
  }

  void visitElementElement(Element node) {
    // TODO(jmesserly): what do we do in this case? It seems like an <element>
    // inside a Shadow DOM should be scoped to that <template> tag, and not
    // visible from the outside.
    if (_currentInfo is ComponentInfo) {
      _messages.error('Nested component definitions are not yet supported.',
          node.sourceSpan, file: _fileInfo.inputPath);
      return;
    }

    var tagName = node.attributes['name'];
    var extendsTag = node.attributes['extends'];
    var templateNodes = node.nodes.where((n) => n.tagName == 'template');

    if (tagName == null) {
      _messages.error('Missing tag name of the component. Please include an '
          'attribute like \'name="your-tag-name"\'.',
          node.sourceSpan, file: _fileInfo.inputPath);
      return;
    }

    if (extendsTag == null) {
      // From the spec:
      // http://dvcs.w3.org/hg/webcomponents/raw-file/tip/spec/custom/index.html#extensions-to-document-interface
      // If PROTOTYPE is null, let PROTOTYPE be the interface prototype object
      // for the HTMLSpanElement interface.
      extendsTag = 'span';
    }

    var template = null;
    if (templateNodes.length == 1) {
      template = templateNodes.single;
    } else {
      _messages.warning('an <element> should have exactly one <template> child',
          node.sourceSpan, file: _fileInfo.inputPath);
    }

    var component = new ComponentInfo(node, _fileInfo, tagName, extendsTag,
        template);

    _fileInfo.declaredComponents.add(component);

    var lastInfo = _currentInfo;
    _currentInfo = component;
    super.visitElement(node);
    _currentInfo = lastInfo;
  }


  void visitScriptElement(Element node) {
    var scriptType = node.attributes['type'];
    var src = node.attributes["src"];

    if (scriptType == null) {
      // Note: in html5 leaving off type= is fine, but it defaults to
      // text/javascript. Because this might be a common error, we warn about it
      // in two cases:
      //   * an inline script tag in a web component
      //   * a script src= if the src file ends in .dart (component or not)
      //
      // The hope is that neither of these cases should break existing valid
      // code, but that they'll help component authors avoid having their Dart
      // code accidentally interpreted as JavaScript by the browser.
      if (src == null && _currentInfo is ComponentInfo) {
        _messages.warning('script tag in component with no type will '
            'be treated as JavaScript. Did you forget type="application/dart"?',
            node.sourceSpan, file: _fileInfo.inputPath);
      }
      if (src != null && src.endsWith('.dart')) {
        _messages.warning('script tag with .dart source file but no type will '
            'be treated as JavaScript. Did you forget type="application/dart"?',
            node.sourceSpan, file: _fileInfo.inputPath);
      }
      return;
    }

    if (scriptType != 'application/dart') {
      if (_currentInfo is ComponentInfo) {
        // TODO(jmesserly): this warning should not be here, but our compiler
        // does the wrong thing and it could cause surprising behavior, so let
        // the user know! See issue #340 for more info.
        // What we should be doing: leave JS component untouched by compiler.
        _messages.warning('our custom element implementation does not support '
            'JavaScript components yet. If this is affecting you please let us '
            'know at https://github.com/dart-lang/web-ui/issues/340.',
            node.sourceSpan, file: _fileInfo.inputPath);
      }

      return;
    }

    if (src != null) {
      if (!src.endsWith('.dart')) {
        _messages.warning('"application/dart" scripts should '
            'use the .dart file extension.',
            node.sourceSpan, file: _fileInfo.inputPath);
      }

      if (node.innerHtml.trim() != '') {
        _messages.error('script tag has "src" attribute and also has script '
            'text.', node.sourceSpan, file: _fileInfo.inputPath);
      }

      if (_currentInfo.codeAttached) {
        _tooManyScriptsError(node);
      } else {
        if (path.isAbsolute(src)) {
          _messages.error(
              'script tag should not use absolute path in attribute "src". '
              'Got "src"="$src".', node.sourceSpan, file: _fileInfo.inputPath);
        } else {
          _currentInfo.externalFile = path.normalize(
              path.join(path.dirname(_fileInfo.inputPath), src));
        }
      }
      return;
    }

    if (node.nodes.length == 0) return;

    // I don't think the html5 parser will emit a tree with more than
    // one child of <script>
    assert(node.nodes.length == 1);
    Text text = node.nodes[0];

    if (_currentInfo.codeAttached) {
      _tooManyScriptsError(node);
    } else if (_currentInfo == _fileInfo && !_fileInfo.isEntryPoint) {
      _messages.warning('top-level dart code is ignored on '
          ' HTML pages that define components, but are not the entry HTML '
          'file.', node.sourceSpan, file: _fileInfo.inputPath);
    } else {
      _currentInfo.inlinedCode = parseDartCode(
          _currentInfo.dartCodePath, text.value, _messages,
          text.sourceSpan.start);
      if (_currentInfo.userCode.partOf != null) {
        _messages.error('expected a library, not a part.',
            node.sourceSpan, file: _fileInfo.inputPath);
      }
    }
  }

  void _tooManyScriptsError(Node node) {
    var location = _currentInfo is ComponentInfo ?
        'a custom element declaration' : 'the top-level HTML page';

    _messages.error('there should be only one dart script tag in $location.',
        node.sourceSpan, file: _fileInfo.inputPath);
  }
}


/**
 * Parses double-curly data bindings within a string, such as
 * `foo {{bar}} baz {{quux}}`.
 *
 * Note that a double curly always closes the binding expression, and nesting
 * is not supported. This seems like a reasonable assumption, given that these
 * will be specified for HTML, and they will require a Dart or JavaScript
 * parser to parse the expressions.
 */
class BindingParser {
  final String text;
  int previousEnd;
  int start;
  int end = 0;

  BindingParser(this.text);

  int get length => text.length;

  String get textContent {
    if (start == null) throw new StateError('iteration not started');
    return text.substring(previousEnd, start);
  }

  BindingInfo get binding {
    if (start == null) throw new StateError('iteration not started');
    if (end < 0) throw new StateError('no more bindings');
    return new BindingInfo.fromText(text.substring(start + 2, end - 2));
  }

  bool moveNext() {
    if (end < 0) return false;

    previousEnd = end;
    start = text.indexOf('{{', end);
    if (start < 0) {
      end = -1;
      start = length;
      return false;
    }

    end = text.indexOf('}}', start);
    if (end < 0) {
      start = length;
      return false;
    }
    // For consistency, start and end both include the curly braces.
    end += 2;
    return true;
  }

  /**
   * Parses all bindings and contents and store them in the provided arguments.
   */
  void readAll(List<BindingInfo> bindings, List<String> content) {
    if (start == null) moveNext();
    if (start < length) {
      do {
        bindings.add(binding);
        content.add(textContent);
      } while (moveNext());
    }
    content.add(textContent);
  }
}
