// Copyright (c) 2016, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

library fasta.verifier;

import 'package:_fe_analyzer_shared/src/messages/severity.dart' show Severity;

import 'package:kernel/ast.dart';
import 'package:kernel/target/targets.dart';

import 'package:kernel/transformations/flags.dart' show TransformerFlag;

import 'package:kernel/type_environment.dart' show TypeEnvironment;

import 'package:kernel/verifier.dart'
    show VerifyGetStaticType, VerifyingVisitor;

import '../compiler_context.dart' show CompilerContext;

import '../fasta_codes.dart'
    show
        LocatedMessage,
        Message,
        messageVerificationErrorOriginContext,
        noLength,
        templateInternalProblemVerificationError;

import '../type_inference/type_schema.dart' show UnknownType;

import 'redirecting_factory_body.dart'
    show
        RedirectingFactoryBody,
        isRedirectingFactory,
        isRedirectingFactoryField;

List<LocatedMessage> verifyComponent(Component component, Target target,
    {bool? isOutline, bool? afterConst, bool skipPlatform: false}) {
  FastaVerifyingVisitor verifier = new FastaVerifyingVisitor(target,
      isOutline: isOutline, afterConst: afterConst, skipPlatform: skipPlatform);
  component.accept(verifier);
  return verifier.errors;
}

class FastaVerifyingVisitor extends VerifyingVisitor {
  final Target target;
  final List<LocatedMessage> errors = <LocatedMessage>[];

  Uri? fileUri;
  final List<TreeNode> treeNodeStack = <TreeNode>[];
  final bool skipPlatform;

  FastaVerifyingVisitor(this.target,
      {bool? isOutline, bool? afterConst, required this.skipPlatform})
      : super(
            isOutline: isOutline,
            afterConst: afterConst,
            constantsAreAlwaysInlined:
                target.constantsBackend.alwaysInlineConstants);

  /// Invoked by all visit methods if the visited node is a [TreeNode].
  void enterTreeNode(TreeNode node) {
    treeNodeStack.add(node);
  }

  /// Invoked by all visit methods if the visited node is a [TreeNode].
  void exitTreeNode(TreeNode node) {
    if (treeNodeStack.isEmpty) {
      throw new StateError("Attempting to exit tree node '${node}' "
          "when the tree node stack is empty.");
    }
    if (!identical(treeNodeStack.last, node)) {
      throw new StateError("Attempting to exit tree node '${node}' "
          "when another node '${treeNodeStack.last}' is active.");
    }
    treeNodeStack.removeLast();
  }

  TreeNode? getLastSeenTreeNode({bool withLocation = false}) {
    assert(treeNodeStack.isNotEmpty);
    for (int i = treeNodeStack.length - 1; i >= 0; --i) {
      TreeNode node = treeNodeStack[i];
      if (withLocation && !_hasLocation(node)) continue;
      return node;
    }
    return null;
  }

  TreeNode? getSameLibraryLastSeenTreeNode({bool withLocation = false}) {
    if (treeNodeStack.isEmpty) return null;
    // ignore: unnecessary_null_comparison
    if (currentLibrary == null || currentLibrary!.fileUri == null) return null;

    for (int i = treeNodeStack.length - 1; i >= 0; --i) {
      TreeNode node = treeNodeStack[i];
      if (withLocation && !_hasLocation(node)) continue;
      if (node.location?.file != null &&
          node.location!.file == currentLibrary!.fileUri) {
        return node;
      }
    }
    return null;
  }

  static bool _hasLocation(TreeNode node) {
    return node.location != null &&
        // ignore: unnecessary_null_comparison
        node.location!.file != null &&
        // ignore: unnecessary_null_comparison
        node.fileOffset != null &&
        node.fileOffset != -1;
  }

  static bool _isInSameLibrary(Library? library, TreeNode node) {
    if (library == null) return false;
    // ignore: unnecessary_null_comparison
    if (library.fileUri == null) return false;
    if (node.location == null) return false;
    // ignore: unnecessary_null_comparison
    if (node.location!.file == null) return false;

    return library.fileUri == node.location!.file;
  }

  TreeNode? get localContext {
    TreeNode? result = getSameLibraryLastSeenTreeNode(withLocation: true);
    if (result == null &&
        currentClassOrExtensionOrMember != null &&
        _isInSameLibrary(currentLibrary, currentClassOrExtensionOrMember!)) {
      result = currentClassOrExtensionOrMember;
    }
    return result;
  }

  TreeNode? get remoteContext {
    TreeNode? result = getLastSeenTreeNode(withLocation: true);
    if (result != null && _isInSameLibrary(currentLibrary, result)) {
      result = null;
    }
    return result;
  }

  Uri checkLocation(TreeNode node, String? name, Uri fileUri) {
    if (name == null || name.contains("#")) {
      // TODO(ahe): Investigate if these checks can be enabled:
      // if (node.fileUri != null && node is! Library) {
      //   problem(node, "A synthetic node shouldn't have a fileUri",
      //       context: node);
      // }
      // if (node.fileOffset != -1) {
      //   problem(node, "A synthetic node shouldn't have a fileOffset",
      //       context: node);
      // }
      return fileUri;
    } else {
      // ignore: unnecessary_null_comparison
      if (fileUri == null) {
        problem(node, "'$name' has no fileUri", context: node);
        return fileUri;
      }
      if (node.fileOffset == -1 && node is! Library) {
        problem(node, "'$name' has no fileOffset", context: node);
      }
      return fileUri;
    }
  }

  void checkSuperInvocation(TreeNode node) {
    Member? containingMember = getContainingMember(node);
    if (containingMember == null) {
      problem(node, 'Super call outside of any member');
    } else {
      if (containingMember.transformerFlags & TransformerFlag.superCalls == 0) {
        problem(
            node, 'Super call in a member lacking TransformerFlag.superCalls');
      }
    }
  }

  Member? getContainingMember(TreeNode? node) {
    while (node != null) {
      if (node is Member) return node;
      node = node.parent;
    }
    return null;
  }

  @override
  void problem(TreeNode? node, String details,
      {TreeNode? context, TreeNode? origin}) {
    node ??= (context ?? currentClassOrExtensionOrMember);
    int offset = node?.fileOffset ?? -1;
    Uri? file = node?.location?.file ?? fileUri;
    Uri? uri = file == null ? null : file;
    Message message =
        templateInternalProblemVerificationError.withArguments(details);
    LocatedMessage locatedMessage = uri != null
        ? message.withLocation(uri, offset, noLength)
        : message.withoutLocation();
    List<LocatedMessage>? contextMessages;
    if (origin != null) {
      contextMessages = [
        messageVerificationErrorOriginContext.withLocation(
            origin.location!.file, origin.fileOffset, noLength)
      ];
    }
    CompilerContext.current
        .report(locatedMessage, Severity.error, context: contextMessages);
    errors.add(locatedMessage);
  }

  @override
  void visitAsExpression(AsExpression node) {
    enterTreeNode(node);
    super.visitAsExpression(node);
    if (node.fileOffset == -1) {
      TreeNode? parent = node.parent;
      while (parent != null) {
        if (parent.fileOffset != -1) break;
        parent = parent.parent;
      }
      problem(parent, "No offset for $node", context: node);
    }
    exitTreeNode(node);
  }

  @override
  void visitExpressionStatement(ExpressionStatement node) {
    // Bypass verification of the [StaticGet] in [RedirectingFactoryBody] as
    // this is a static get without a getter.
    if (node is! RedirectingFactoryBody) {
      enterTreeNode(node);
      super.visitExpressionStatement(node);
      exitTreeNode(node);
    }
  }

  @override
  void visitLibrary(Library node) {
    // Issue(http://dartbug.com/32530)
    // 'dart:test' is used in the unit tests and isn't an actual part of the
    // platform.
    if (skipPlatform &&
        node.importUri.isScheme('dart') &&
        node.importUri.path != 'test') {
      return;
    }

    enterTreeNode(node);
    fileUri = checkLocation(node, node.name, node.fileUri);
    currentLibrary = node;
    super.visitLibrary(node);
    currentLibrary = null;
    exitTreeNode(node);
  }

  @override
  void visitClass(Class node) {
    enterTreeNode(node);
    fileUri = checkLocation(node, node.name, node.fileUri);
    super.visitClass(node);
    exitTreeNode(node);
  }

  @override
  void visitExtension(Extension node) {
    enterTreeNode(node);
    fileUri = checkLocation(node, node.name, node.fileUri);
    super.visitExtension(node);
    exitTreeNode(node);
  }

  @override
  void visitField(Field node) {
    enterTreeNode(node);
    fileUri = checkLocation(node, node.name.text, node.fileUri);
    super.visitField(node);
    exitTreeNode(node);
  }

  @override
  void visitProcedure(Procedure node) {
    enterTreeNode(node);
    fileUri = checkLocation(node, node.name.text, node.fileUri);

    // TODO(cstefantsova): Investigate why some redirecting factory bodies
    // retain the shape, but aren't of the RedirectingFactoryBody type.
    bool hasBody = isRedirectingFactory(node) ||
        RedirectingFactoryBody.hasRedirectingFactoryBodyShape(node);
    bool hasFlag = node.isRedirectingFactory;
    if (hasFlag && !hasBody) {
      problem(
          node,
          "Procedure '${node.name}' doesn't have a body "
          "of a redirecting factory, but has the "
          "'isRedirectingFactory' bit set.");
    }

    super.visitProcedure(node);
    exitTreeNode(node);
  }

  bool isNullType(DartType node) => node is NullType;

  bool isObjectClass(Class c) {
    return c.name == "Object" &&
        c.enclosingLibrary.importUri.isScheme("dart") &&
        c.enclosingLibrary.importUri.path == "core";
  }

  bool isTopType(DartType node) {
    return node is DynamicType ||
        node is VoidType ||
        node is InterfaceType &&
            isObjectClass(node.classNode) &&
            (node.nullability == Nullability.nullable ||
                node.nullability == Nullability.legacy) ||
        node is FutureOrType && isTopType(node.typeArgument);
  }

  bool isFutureOrNull(DartType node) {
    return isNullType(node) ||
        node is FutureOrType && isFutureOrNull(node.typeArgument);
  }

  @override
  void defaultDartType(DartType node) {
    final TreeNode? localContext = this.localContext;
    final TreeNode? remoteContext = this.remoteContext;

    if (node is UnknownType) {
      problem(localContext, "Unexpected appearance of the unknown type.",
          origin: remoteContext);
    }

    // TODO(johnniwinther): This check wasn't called from InterfaceType and
    // is currently very broken. Disabling for now.
    /*bool isTypeCast = localContext != null &&
        localContext is AsExpression &&
        localContext.isTypeError;
    // Don't check cases like foo(x as{TypeError} T).  In cases where foo comes
    // from a library with a different opt-in status than the current library,
    // the check may not be necessary.  For now, just skip all type-error casts.
    // TODO(cstefantsova): Implement a more precise analysis.
    bool isFromAnotherLibrary = remoteContext != null || isTypeCast;

    // Checking for non-legacy types in opt-out libraries.
    {
      bool neverLegacy = isNullType(node) ||
          isFutureOrNull(node) ||
          isTopType(node) ||
          node is InvalidType ||
          node is NeverType ||
          node is BottomType;
      // TODO(cstefantsova): Consider checking types coming from other
      // libraries.
      bool expectedLegacy = !isFromAnotherLibrary &&
          !currentLibrary.isNonNullableByDefault &&
          !neverLegacy;
      if (expectedLegacy && node.nullability != Nullability.legacy) {
        problem(localContext,
            "Found a non-legacy type '${node}' in an opted-out library.",
            origin: remoteContext);
      }
    }

    // Checking for legacy types in opt-in libraries.
    {
      Nullability nodeNullability =
          node is InvalidType ? Nullability.undetermined : node.nullability;
      // TODO(cstefantsova): Consider checking types coming from other
      // libraries.
      if (!isFromAnotherLibrary &&
          currentLibrary.isNonNullableByDefault &&
          nodeNullability == Nullability.legacy) {
        problem(localContext,
            "Found a legacy type '${node}' in an opted-in library.",
            origin: remoteContext);
      }
    }*/

    super.defaultDartType(node);
  }

  @override
  void visitFunctionType(FunctionType node) {
    if (node.typeParameters.isNotEmpty) {
      for (TypeParameter typeParameter in node.typeParameters) {
        if (typeParameter.parent != null) {
          problem(
              localContext,
              "Type parameters of function types shouldn't have parents: "
              "$node.");
        }
      }
    }
    super.visitFunctionType(node);
  }

  @override
  void visitInterfaceType(InterfaceType node) {
    if (isNullType(node) && node.nullability != Nullability.nullable) {
      problem(localContext, "Found a not nullable Null type: ${node}");
    }
    super.visitInterfaceType(node);
  }

  @override
  void visitSuperMethodInvocation(SuperMethodInvocation node) {
    enterTreeNode(node);
    checkSuperInvocation(node);
    super.visitSuperMethodInvocation(node);
    exitTreeNode(node);
  }

  @override
  void visitSuperPropertyGet(SuperPropertyGet node) {
    enterTreeNode(node);
    checkSuperInvocation(node);
    super.visitSuperPropertyGet(node);
    exitTreeNode(node);
  }

  @override
  void visitSuperPropertySet(SuperPropertySet node) {
    enterTreeNode(node);
    checkSuperInvocation(node);
    super.visitSuperPropertySet(node);
    exitTreeNode(node);
  }

  @override
  void visitStaticInvocation(StaticInvocation node) {
    enterTreeNode(node);
    super.visitStaticInvocation(node);
    exitTreeNode(node);
  }

  void _checkConstructorTearOff(Node node, Member tearOffTarget) {
    if (tearOffTarget.enclosingLibrary.importUri.isScheme('dart')) {
      // Platform libraries are not compilation with test flags and might
      // contain tear-offs not expected when testing lowerings.
      return;
    }
    if (currentMember != null && isRedirectingFactoryField(currentMember!)) {
      // The encoding of the redirecting factory field uses
      // [ConstructorTearOffConstant] nodes also when lowerings are enabled.
      return;
    }
    if (tearOffTarget is Constructor &&
        target.isConstructorTearOffLoweringEnabled) {
      problem(
          node is TreeNode ? node : getLastSeenTreeNode(),
          '${node.runtimeType} nodes for generative constructors should be '
          'lowered for target "${target.name}".');
    }
    if (tearOffTarget is Procedure &&
        tearOffTarget.isFactory &&
        target.isFactoryTearOffLoweringEnabled) {
      problem(
          node is TreeNode ? node : getLastSeenTreeNode(),
          '${node.runtimeType} nodes for factory constructors should be '
          'lowered for target "${target.name}".');
    }
  }

  @override
  void visitConstructorTearOff(ConstructorTearOff node) {
    _checkConstructorTearOff(node, node.target);
    super.visitConstructorTearOff(node);
  }

  @override
  void visitConstructorTearOffConstant(ConstructorTearOffConstant node) {
    _checkConstructorTearOff(node, node.target);
    super.visitConstructorTearOffConstant(node);
  }

  void _checkTypedefTearOff(Node node) {
    if (target.isTypedefTearOffLoweringEnabled) {
      problem(
          node is TreeNode ? node : getLastSeenTreeNode(),
          '${node.runtimeType} nodes for typedefs should be '
          'lowered for target "${target.name}".');
    }
  }

  @override
  void visitTypedefTearOff(TypedefTearOff node) {
    _checkTypedefTearOff(node);
    super.visitTypedefTearOff(node);
  }

  @override
  void visitTypedefTearOffConstant(TypedefTearOffConstant node) {
    _checkTypedefTearOff(node);
    super.visitTypedefTearOffConstant(node);
  }

  void _checkRedirectingFactoryTearOff(Node node) {
    if (target.isRedirectingFactoryTearOffLoweringEnabled) {
      problem(
          node is TreeNode ? node : getLastSeenTreeNode(),
          'ConstructorTearOff nodes for redirecting factories should be '
          'lowered for target "${target.name}".');
    }
  }

  @override
  void visitRedirectingFactoryTearOff(RedirectingFactoryTearOff node) {
    _checkRedirectingFactoryTearOff(node);
    super.visitRedirectingFactoryTearOff(node);
  }

  @override
  void visitRedirectingFactoryTearOffConstant(
      RedirectingFactoryTearOffConstant node) {
    _checkRedirectingFactoryTearOff(node);
    super.visitRedirectingFactoryTearOffConstant(node);
  }

  @override
  void defaultTreeNode(TreeNode node) {
    enterTreeNode(node);
    super.defaultTreeNode(node);
    exitTreeNode(node);
  }
}

void verifyGetStaticType(TypeEnvironment env, Component component,
    {bool skipPlatform: false}) {
  component.accept(new FastaVerifyGetStaticType(env, skipPlatform));
}

class FastaVerifyGetStaticType extends VerifyGetStaticType {
  final bool skipPlatform;

  FastaVerifyGetStaticType(TypeEnvironment env, this.skipPlatform) : super(env);

  @override
  void visitLibrary(Library node) {
    // 'dart:test' is used in the unit tests and isn't an actual part of the
    // platform.
    if (skipPlatform &&
        node.importUri.isScheme('dart') &&
        node.importUri.path != "test") {
      return;
    }

    super.visitLibrary(node);
  }
}
