/**
   Implements tools that are useful especially in unittest blocks.
 */

module alid.test;

import alid.errornogc : NogcError;

private mixin NogcError!"test";

/**
   Compare `a` and `b` and throw an `Error` if they are not equal.

   Params:

       a = left-hand side expression
       b = right-hand side expression
 */
void assertEqual(A, B)(in A a, in B b, in string file = __FILE__, in int line = __LINE__)
{
    if (a == b)
    {
        // All good
    }
    else
    {
        // We are calling the version of `testError` that takes file and line
        // information; otherwise, the location information was pointing at this
        // line. (?)
        testErrorFileLine(file, line, "ERROR: Expressions are not equal.", a, b);
    }
}

///
alias shouldBe = assertEqual;

///
unittest
{
    [1, 2].length.shouldBe(2);
}

unittest
{
    import std.exception : assertThrown, assertNotThrown;

    assertNotThrown!Error(1.shouldBe(1));
    assertNotThrown!Error(42.shouldBe(42.0));
    assertThrown!Error(1.shouldBe(2));
}
