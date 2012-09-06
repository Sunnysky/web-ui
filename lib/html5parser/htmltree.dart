// Copyright (c) 2012, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
// Generated by scripts/tree_gen.py.

#library('htmltree');

#import('../../tools/lib/source.dart');
#import('tokenkind.dart');

#source('tree.dart');

class Identifier extends TreeNode {
  String name;

  Identifier(this.name, SourceSpan span): super(span);

  visit(TreeVisitor visitor) => visitor.visitIdentifier(this);

  String toString() => name;
}

class StringValue extends TreeNode {
  String value;

  StringValue(this.value, SourceSpan span): super(span);

  visit(TreeVisitor visitor) => visitor.visitStringValue(this);

  String toString() => value;
}

// CDO/CDC (Comment Definition Open <!-- and Comment Definition Close -->).
class CommentDefinition extends TreeNode {
  String comment;

  CommentDefinition(this.comment, SourceSpan span): super(span);

  visit(TreeVisitor visitor) => visitor.visitCommentDefinition(this);

  String toString() => '<!-- ${comment} -->';
}

class Template extends HTMLElement {
  static const String IF_COMPONENT = "x-if";
  static const String LIST_COMPONENT = "x-list";

  final String instantiate;
  final String iterate;

  /** Attribute is encountered; the web component being used. */
  final String webComponent;

  Template(List<HTMLAttribute> attrs, SourceSpan span)
      : instantiate = "",
        iterate = "",
        webComponent = null,
        super.template(attrs, span);
  Template.createInstantiate(List<HTMLAttribute> attrs, this.instantiate,
      SourceSpan span)
      : iterate = "",
        webComponent = null,
        super.template(attrs, span);
  Template.createIterate(List<HTMLAttribute> attrs, this.iterate, SourceSpan span)
      : instantiate = "",
        webComponent = LIST_COMPONENT,
        super.template(attrs, span);
  Template.createConditional(List<HTMLAttribute> attrs, this.instantiate, SourceSpan span)
      : iterate = "",
        webComponent = IF_COMPONENT,
        super.template(attrs, span);

  bool get hasInstantiate => instantiate != null && !instantiate.isEmpty();
  bool get hasIterate => iterate != null && !iterate.isEmpty();
  bool get isWebComponent => webComponent != null && !webComponent.isEmpty();
  bool get isConditional =>
      hasInstantiate && !hasIterate && webComponent == IF_COMPONENT;

  visit(TreeVisitor visitor) => visitor.visitTemplate(this);

  String attributesToString([bool allAttr = true]) {
    StringBuffer buff = new StringBuffer(super.attributesToString(allAttr));

    if (instantiate != null && !instantiate.isEmpty()) {
      buff.add(' instantiate="$instantiate"');
    }
    if (iterate != null && !iterate.isEmpty()) {
      buff.add(' iterate="$iterate"');
    }
    if (isWebComponent) {
      buff.add(' is="$webComponent"');
    }

    return buff.toString();
  }
}

class TemplateParameter extends TreeNode {
  Identifier paramType;
  Identifier paramName;

  TemplateParameter(this.paramType, this.paramName, SourceSpan span):
      super(span);

  visit(TreeVisitor visitor) => visitor.visitTemplateParameter(this);

  String toString() {
    return "$paramType $paramName";
  }
}

class TemplateSignature extends TreeNode {
  String name;
  List<TemplateParameter> params;
//  List<Map<Identifier, Identifier>> params;   // Map of {type:, name:}

  TemplateSignature(this.name, this.params, SourceSpan span): super(span);

  visit(TreeVisitor visitor) => visitor.visitTemplateSignature(this);

  String paramsAsString() {
    StringBuffer buff = new StringBuffer();
    bool first = true;
    for (final param in params) {
      if (!first) {
        buff.add(", ");
      }
      buff.add(param.toString());
      first = false;
    }

    return buff.toString();
  }

  String toString() => "template ${name}(${paramsAsString()})";
}

class HTMLChildren extends TreeNode {
  List<TreeNode> children;

  HTMLChildren(this.children, SourceSpan span): super(span);
  HTMLChildren.empty(SourceSpan span): children = [], super(span);

  add(var child) {
    if (children == null) {
      children = new List<TreeNode>();
    }
    children.add(child);
  }

  TreeNode last() => children.last();
  TreeNode removeLast() => children.removeLast();
  bool get anyChildren => children != null && children.length > 0;

  visit(TreeVisitor visitor) => visitor.visitHTMLChildren(this);

  String toString() {
    StringBuffer buff = new StringBuffer();
    if (children != null) {
      for (final child in children) {
        buff.add(child.toString());
      }
    }

    return buff.toString();
  }

  String generateHTML([bool noScript = true]) {
    StringBuffer buff = new StringBuffer();
    if (children != null) {
      for (final child in children) {
        if (child is HTMLElement) {
          if (!child.isScriptTag) {
            buff.add(child.generateHTML(noScript));
          }
        } else {
          buff.add(child.toString());
        }
      }
    }

    return buff.toString();
  }
}

class TemplateGetter extends TreeNode {
  String name;
  List<TemplateParameter> params;
  HTMLDocument docFrag;

  TemplateGetter(this.name, this.params, this.docFrag, SourceSpan span) :
      super(span);

  visit(TreeVisitor visitor) => visitor.visitTemplateGetter(this);

  String paramsAsString() {
    StringBuffer buff = new StringBuffer();
    bool first = true;
    for (final param in params) {
      if (!first) {
        buff.add(", ");
      }
      buff.add(param.toString());
      first = false;
    }

    return buff.toString();
  }

  String getterSignatureAsString() => "${name}(${paramsAsString()})";
}

class HTMLDocument extends HTMLChildren {
  /** Controller associated with this document. */
  String dataController;

  HTMLDocument(this.dataController, List<TreeNode> children, SourceSpan span):
    super(children, span);

  bool get hasDataController =>
      dataController != null && !dataController.isEmpty();

  visit(TreeVisitor visitor) => visitor.visitHTMLDocument(this);
}

/** Token id for a fragment. */
const int TAG_FRAGMENT = -1;

/** Token id for an unknown tag. */
const int TAG_XTAG = -2;

class HTMLElement extends HTMLChildren {
  int tagTokenId;
  List<HTMLAttribute> attributes;
  String _varName;
  String _idName;

  HTMLElement(this.tagTokenId, SourceSpan span) : super.empty(span);
  HTMLElement.fragment(SourceSpan span) : super.empty(span),
      tagTokenId = TAG_FRAGMENT;
  HTMLElement.createAttributes(this.tagTokenId, this.attributes, this._varName,
    SourceSpan span) : super.empty(span);
  HTMLElement.template(this.attributes, SourceSpan span)
      : tagTokenId = TokenKind.TEMPLATE,
        super.empty(span);

  bool get isFragment => tagTokenId == TAG_FRAGMENT;
  bool get anyAttributes => attributes != null;
  bool get isXTag => false;
  bool get isUnscoped => TokenKind.unscopedTag(tagTokenId);

  bool get isScriptTag => tagTokenId == TokenKind.SCRIPT_ELEMENT;

  visit(TreeVisitor visitor) => visitor.visitHTMLElement(this);

  bool get hasIdName => _idName != null;
  String get idName => hasIdName ? _idName : null;

  bool get hasVar => _varName != null;
  String get varName => hasVar ? _varName : null;

  String attributesToString([bool allAttr = true]) {
    StringBuffer buff = new StringBuffer();

    if (attributes != null) {
      for (final attr in attributes) {
        if (allAttr || !(attr is TemplateAttributeExpression)) {
          buff.add(' ${attr.toString()}');
        }
      }
    }

    return buff.toString();
  }

  String get tagName => isFragment ?
    'root' : TokenKind.tagNameFromTokenId(tagTokenId);

  bool get scoped => !TokenKind.unscopedTag(tagTokenId);

  String tagStartToString([bool allAttrs = true]) =>
      "<${tagName}${attributesToString(allAttrs)}>";

  String tagEndToString() => "</${tagName}>";

  String generateHTML([bool noScript = true]) {
    StringBuffer buff = new StringBuffer();

    if (noScript && isScriptTag) {
      return "";
    }

    if (!isFragment) {
      buff.add(tagStartToString());
    }

    if (children != null) {
      for (final child in children) {
        if (child is HTMLElement) {
          HTMLElement elem = child;
          buff.add(elem.generateHTML(noScript));
        } else {
          buff.add(child.toString());
        }
      }

      if (!isFragment && !isUnscoped) {
        buff.add(tagEndToString());
      }
    }

    return buff.toString();
  }

  String toString() {
    StringBuffer buff = new StringBuffer(tagStartToString());

    if (children != null) {
      for (final child in children) {
        buff.add(child.toString());
      }

      buff.add(tagEndToString());
    }

    return buff.toString();
  }

  String toStringNoExpressions() {
    StringBuffer buff = new StringBuffer(tagStartToString(false));

    if (children != null) {
      for (final child in children) {
        buff.add(child.toString());
      }

      buff.add(tagEndToString());
    }

    return buff.toString();
  }
}

/** XTag */
class HTMLUnknownElement extends HTMLElement {
  String xTag;

  HTMLUnknownElement(this.xTag, SourceSpan span): super(TAG_XTAG, span);
  HTMLUnknownElement.fragment(SourceSpan span) : super.fragment(span);
  HTMLUnknownElement.attributes(this.xTag, List<HTMLAttribute> attrs,
      String varName, SourceSpan span)
      : super.createAttributes(TAG_XTAG, attrs, varName, span);

  bool get isXTag => true;

  String get tagName => isXTag ? xTag : 'root';

  bool get scoped => true;

  visit(TreeVisitor visitor) => visitor.visitHTMLUnknownElement(this);
}

class HTMLAttribute extends TreeNode {
  String name;
  String value;

  HTMLAttribute(this.name, this.value, SourceSpan span): super(span);

  bool get isExpression => false;

  visit(TreeVisitor visitor) => visitor.visitHTMLAttribute(this);

  String toString() => "${name}=\"${value}\"";
}

class TemplateAttributeExpression extends HTMLAttribute {
  TemplateAttributeExpression(String name, String value, SourceSpan span):
      super(name, value, span);

  bool get isExpression => true;

  visit(TreeVisitor visitor) => visitor.visitTemplateAttributeExpression(this);

  String toString() => "${name}=\"{{${value}}}\"";
}

class HTMLText extends TreeNode {
  String value;

  HTMLText(this.value, SourceSpan span): super(span);

  visit(TreeVisitor visitor) => visitor.visitHTMLText(this);

  String toString() => value;
}

class TemplateExpression extends TreeNode {
  String expression;

  TemplateExpression(this.expression, SourceSpan span): super(span);

  visit(TreeVisitor visitor) => visitor.visitTemplateExpression(this);

  String toString() => "{{$expression}}";
}

class TemplateCall extends TreeNode {
  String toCall;
  String params;

  TemplateCall(this.toCall, this.params, SourceSpan span): super(span);

  visit(TreeVisitor visitor) => visitor.visitTemplateCall(this);

  String toString() => "\$\{#${toCall}${params}}";
}

interface TreeVisitor {
  void visitIdentifier(Identifier node);
  void visitStringValue(StringValue node);
  void visitCommentDefinition(CommentDefinition node);
  void visitTemplate(Template node);
  void visitTemplateParameter(TemplateParameter node);
  void visitTemplateSignature(TemplateSignature node);
  void visitHTMLChildren(HTMLChildren node);
  void visitHTMLDocument(HTMLDocument node);
  void visitHTMLElement(HTMLElement node);
  void visitHTMLUnknownElement(HTMLUnknownElement node);
  void visitHTMLAttribute(HTMLAttribute node);
  void visitTemplateAttributeExpression(TemplateAttributeExpression node);
  void visitHTMLText(HTMLText node);
  void visitTemplateExpression(TemplateExpression node);
  void visitTemplateCall(TemplateCall node);
  void visitTemplateGetter(TemplateGetter node);
}

class TreePrinter implements TreeVisitor {
  var output;
  TreePrinter(this.output) { output.printer = this; }

  void visitIdentifier(Identifier node) {
    output.heading('Identifier(${output.toValue(node.name)})', node.span);
  }

  void visitStringValue(StringValue node) {
    output.heading('"${output.toValue(node.value)}"', node.span);
  }

  void visitCommentDefinition(CommentDefinition node) {
    output.heading('CommentDefinition (CDO/CDC)', node.span);
    output.depth++;
    output.writeValue('comment value', node.comment);
    output.depth--;
  }

  void visitTemplate(Template node) {
    output.heading('Template', node.span);
    output.depth++;
    output.writeValue('Instantiate', node.instantiate);
    output.writeValue('Iterate', node.iterate);
    output.writeValue('WebComponent', node.webComponent);
    visitHTMLChildren(node);
    output.depth--;
  }

  void visitTemplateParameter(TemplateParameter node) {
    output.heading('visitTemplateParameter', node.span);
    output.depth++;
    output.writeValue('Parameter', node);
    output.depth--;
  }

  void visitTemplateSignature(TemplateSignature node) {
    output.heading('TemplateSignature', node.span);
    output.depth++;
    output.writeNodeList('parameters', node.params);
    output.writeValue('Template', node);
    output.depth--;
  }

  void visitHTMLChildren(HTMLChildren node) {
    output.writeNodeList('children', node.children);
  }

  void visitHTMLDocument(HTMLDocument node) {
    output.heading('Content', node.span);
    output.depth++;
    // TODO(terry): Ugly use dynamic[0] instead children[0] to surpress warning.
    assert(node.children.length == 1 &&
        node.children.dynamic[0].tagTokenId == TAG_FRAGMENT);
    output.writeValue("dataController", node.dataController);
    output.writeNodeList("document", node.children);
    output.depth--;
  }

  void visitHTMLElement(HTMLElement node) {
    output.heading('Element', node.span);
    output.depth++;
    output.writeValue('tag', node.tagName);
    if (node.attributes != null && (node.attributes.length > 0)) {
      output.writeNodeList("attributes", node.attributes);
    }
    visitHTMLChildren(node);
    output.depth--;
  }

  void visitHTMLUnknownElement(HTMLElement node) {
    output.heading('Unknown Element', node.span);
    output.depth++;
    output.writeValue('tag', node.tagName);
    if (node.attributes != null && (node.attributes.length > 0)) {
      output.writeNodeList("attributes", node.attributes);
    }
    visitHTMLChildren(node);
    output.depth--;
  }

  void visitHTMLAttribute(HTMLAttribute node) {
    output.heading('Attribute', node.span);
    output.depth++;
    output.writeValue('name', node.name);
    output.writeValue('value', node.value);
    output.depth--;
  }

  void visitTemplateAttributeExpression(TemplateAttributeExpression node) {
    output.heading('Attribute Expression', node.span);
    output.depth++;
    output.writeValue('name', node.name);
    output.writeValue('expression', "{{${node.value}}}");
    output.depth--;
  }

  void visitHTMLText(HTMLText node) {
    output.heading('Text', node.span);
    output.writeValue('value', node.value);
  }

  void visitTemplateExpression(TemplateExpression node) {
    output.heading('Template Expression', node.span);
    output.writeValue('expression', "{{${node.expression}}}");
  }

  void visitTemplateCall(TemplateCall node) {
    output.heading('#call template', node.span);
    output.writeValue('templateToCall', node.toCall);
    output.writeValue('params', node.params);
  }

  void visitTemplateGetter(TemplateGetter node) {
    output.heading('template getter', node.span);
    output.writeValue('getter Signature', node.getterSignatureAsString());
    visitHTMLDocument(node.docFrag);
  }
}

