// Copyright (c) 2018, the Dart project authors.  Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.
// @dart=2.9
class I<X> {}

class J<X> {}

mixin M0<X, Y> on I<X>, J<Y> {}

class M1 implements I<int> {}

class M2 extends M1 implements J<double> {}

// M0 is inferred as M0<int, double>
class A extends M2 with M0 {}

main() {}
