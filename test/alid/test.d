/**
   Implements tools that are useful especially in unittest blocks.
 */

module alid.test;

/**
   Compare `a` and `b` and throw an `Error` if they are not equal.

   Params:

       a = left-hand side expression
       b = right-hand side expression
 */
void assertEqual(A, B)(A a, B b, in string file = __FILE__, in int line = __LINE__)
{
    import std.algorithm : equal;

    static if (__traits(compiles, a.equal(b)))
    {
        alias expr = () => a.equal(b);
    }
    else
    {
        alias expr = () => a == b;
    }

    if (expr())
    {
        // All good
    }
    else
    {
        import std.format : format;
        assert(false, format!"\n%s:%s:Expressions are not equal: %s != %s"(
                   file, line, a, b));
    }
}

///
alias shouldBe = assertEqual;

///
nothrow pure @safe
unittest
{
    [1, 2].length.shouldBe(2);
}

pure
unittest
{
    import std.exception : assertThrown, assertNotThrown;

    assertNotThrown!Error(1.shouldBe(1));
    assertNotThrown!Error(42.shouldBe(42.0));
    assertThrown!Error(1.shouldBe(2));
}

pure
unittest
{
    import std.range : iota;
    iota(10).shouldBe(iota(0, 10, 1));
}
