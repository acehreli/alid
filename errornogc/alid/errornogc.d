/**
   Implements a mixin template that allows throwing Errors from `@nogc` code.
 */

module alid.errornogc;

/**
    Mixes in the definition of a subclass of `Error` as well as a convenience
    function (e.g. `myError()`) to throw the single thread-local instance of
    that class.

    The creation of the single instance is `@nogc` because the object that is
    thrown is emplaced on a thread-local memory buffer. And throwing is `@nogc`
    because the thrown object is the single thread-local instance. Each
    `NogcError` object can carry arbitrary number of data of arbitrary types,
    which are emplaced inside the single error object. The size of data storage
    is specified with the `maxDataSize` template parameter.

    The following examples use the `NogcError!"foo"` type and its associated
    `fooError()` function, which can be defined similarly to the following code:
    ---
    // Define NogcError_!"foo", which will be thrown by calling fooError():
    mixin NogcError!"foo";
    ---

    Params:

        tag = a differentiating type _tag to allow multiple NogcError types with
              their associated single instances

        maxDataSize = the size of the buffer to hold additional data accompanying
                      the thrown error object

    Bugs:

        The error data that is emplaced inside the error object are never
        destroyed. This decision is supported by the realization that the
        program is about to end due to the thrown NogcError.
 */
mixin template NogcError(string tag, size_t maxDataSize = 1024)
{
    private class NogcError_ : Error
    {
        string msg;                // Main error message
        ubyte[maxDataSize] data_;  // Additional information associated with the error
        size_t dataOffset;         // Determines where aligned data starts
        size_t dataSize;           // Determines the size of data

        // The lambda that knows how to print the type-erased data
        void function(void delegate(in char[]), const(ubyte)*) dataToStr;

        enum name = `NogcError!"` ~ tag ~ '"';

        this() @nogc nothrow pure @safe scope
        {
            super(name);
        }

        // Where actual data is at after considering alignment offset
        inout(ubyte)* dataStart_() inout @nogc nothrow pure @trusted scope
        {
            return data_.ptr + dataOffset;
        }

        // Adapted from object.Throwable.toString
        override
        void toString(scope void delegate(in char[]) sink) const nothrow scope
        {
            try
            {
                import std.conv : to;

                sink(file); sink(":"); sink(line.to!string); sink(": ");
                sink(name); sink(": "); sink(msg);

                if (dataSize)
                {
                    sink("\n  Data: ");
                    if (dataToStr)
                    {
                        dataToStr(sink, dataStart_);
                    }
                }

                if (info)
                {
                    sink("\n----------------");
                    foreach (t; info)
                    {
                        sink("\n"); sink(t);
                    }
                }
            }
            catch (Throwable)
            {
                // ignore more errors
            }
        }
    }

    /*
      Allow access to the per-thread NogcError!tag instance.

      The template constraint is to prevent conflicting mixed-in definitions of
      unrelated NogcError instantiations.
    */
    private static ref theError(string t)() @trusted
    if (t == tag)
    {
        static ubyte[__traits(classInstanceSize, NogcError_)] mem_;
        static NogcError_ obj_;

        if (!obj_)
        {
            import core.lifetime : emplace;
            obj_ = emplace!NogcError_(mem_[]);
        }

        return obj_;
    }

    private static string throwNogcError(Data...)(
        string msg, auto ref Data data, string file, in int line) @trusted
    {
        import core.lifetime : emplace;
        import std.algorithm : max;
        import std.format : format;
        import std.typecons : Tuple;

        alias TD = Tuple!Data;
        enum size = (Data.length ? TD.sizeof : 0);
        enum alignment = max(TD.alignof, (void*).alignof);

        // Although this should never happen, being safe before the
        // subtraction below
        static assert (alignment > 0);

        // We will consider alignment against the worst case run-time
        // situation by assuming that the modulus operation would produce 1
        // at run time (very unlikely).
        enum maxDataOffset = alignment - 1;

        static assert((theError!tag.data_.length >= maxDataOffset) &&
                      (size <= (theError!tag.data_.length - maxDataOffset)),
                      format!("Also considering the %s-byte alignment of %s, it is" ~
                              " not possible to fit %s bytes into a %s-byte buffer.")(
                                  alignment, Data.stringof, size, maxDataSize));

        theError!tag.msg = msg;
        theError!tag.file = file;
        theError!tag.line = line;

        // Ensure correct alignment
        const extra = cast(ulong)theError!tag.data_.ptr % alignment;
        theError!tag.dataOffset = alignment - extra;
        theError!tag.dataSize = size;

        emplace(cast(TD*)(theError!tag.dataStart_), TD(data));

        // Save for later printing
        theError!tag.dataToStr = (sink, ptr)
                                 {
                                     import std.conv : to;

                                     auto d = cast(TD*)(ptr);
                                     static foreach (i; 0 .. TD.length)
                                     {
                                         static if (i != 0)
                                         {
                                             sink(", ");
                                         }
                                         sink((*d)[i].to!string);
                                     }
                                 };

        // We can finally throw the single error object
        throw theError!tag;
    }

    /*
        Inject the function for <tag>Error() calls like myError(), yourError(),
        etc. Although the return type of the function is 'string' to satisfy
        e.g. contracts, the function does not return because throwNogcError()
        that it calls throws.
    */
    mixin (`string ` ~ tag ~ `Error(Data...)` ~
           `(in string msg, in Data data,` ~
           ` in string file = __FILE__, in int line = __LINE__)` ~
           `{ return throwNogcError(msg, data, file, line); }`);

    // This version is a workaround for some cases where 'file' and 'line' would
    // become a part of 'data'.
    mixin (`string ` ~ tag ~ `ErrorFileLine(Data...)` ~
           `(in string file, in int line, in string msg, in Data data)` ~
           `{ return throwNogcError(msg, data, file, line); }`);
}

///
unittest
{
    /*
        Throwing from a pre-condition.

        In this case, the error is thrown while generating the string that the
        failed pre-condition is expecting. Such a string will never arrive at
        the pre-condition code.
    */
    void test_1(int i) @nogc nothrow @safe
    in (i > 0, fooError("The value must be positive", i, 42))
    {
        // ...
    }
    /*
        The .msg property of the error contains both the error string and the
        data that is included in the error.
    */
    assertErrorStringContains(() => test_1(-1), [ "The value must be positive",
                                                  "-1, 42" ]);

    // Throwing from the body of a function
    void test_2() @nogc nothrow @safe
    {
        string otherData = "hello world";
        fooError("Something went wrong", otherData);
    }
    assertErrorStringContains(() => test_2(), [ "Something went wrong",
                                                "hello world" ]);

    // Throwing without any data
    void test_3() @nogc nothrow @safe
    {
        fooError("Something is bad");
    }
    assertErrorStringContains(() => test_3(), [ "Something is bad" ]);
}

version (unittest)
{
    // Define NogcError!"foo", which will be thrown by calling fooError():
    private mixin NogcError!"foo";

    // Assert that the expression throws an Error object and that its string
    // representation contains all expected strings.
    private void assertErrorStringContains(
        void delegate() @nogc nothrow @safe expr, string[] expected)
    {
        bool thrown = false;

        try
        {
            expr();
        }
        catch (Error err)
        {
            thrown = true;

            import std.algorithm : any, canFind, splitter;
            import std.conv : to;
            import std.format : format;

            auto lines = err.to!string.splitter('\n');
            foreach (exp; expected)
            {
                assert(lines.any!(line => line.canFind(exp)),
                       format!"Failed to find \"%s\" in the output: %-(\n  |%s%)"(
                           exp, lines));
            }
        }

        assert(thrown, "The expression did not throw an Error.");
    }
}

unittest
{
    // Testing assertErrorStringContains itself

    import std.exception : assertNotThrown, assertThrown;
    import std.format : format;

    // This test requires that bounds checking is active
    int[] arr;
    const i = arr.length;
    auto dg = { ++arr[i]; };    // Intentionally buggy

    // These should fail because "Does not exist" is not a part of out-of-bound
    // Error output:
    assertThrown!Error(assertErrorStringContains(dg, ["Does not exist",
                                                      "out of bounds"]));

    assertThrown!Error(assertErrorStringContains(dg, ["out of bounds",
                                                      "Does not exist"]));

    // This should pass because all provided texts are parts of out-of-bound
    // Error output:
    auto expected = ["out of bounds",
                     format!"[%s]"(i),
                     "ArrayIndexError",
                     format!"array of length %s"(arr.length) ];
    assertNotThrown!Error(assertErrorStringContains(dg, expected));
}

@nogc nothrow @safe
unittest
{
    // Test that large data is caught at compile time

    import std.format : format;
    import std.meta : AliasSeq;

    enum size = theError!"foo".data_.length;

    // Pairs of static arrays of various sizes and whether data should fit
    enum minAlignment = (void*).alignof;
    alias cases = AliasSeq!(ubyte[size / 2 - minAlignment], true,
                            ubyte[size - minAlignment], true,
                            ubyte[size + 1], false,
                            );

    static foreach (i; 0 .. cases.length)
    {
        static if (i % 2 == 0)
        {
            static assert(
                __traits(compiles, fooError("message", cases[i].init)) == cases[i + 1],
                format!"Failed for i: %s, type: %s"(i, cases[i].stringof));
        }
    }
}
