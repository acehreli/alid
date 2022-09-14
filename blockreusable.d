/**
   Implements a memory block to place elements on.
*/

module alid.blockreusable;

import alid.errornogc : NogcError;
import std.typecons : Flag, Yes;

// The Error type that ReusableBlock throws
private mixin NogcError!"block";

/**
   A reusable memory block for placing objects on.

   The elements are added only at the back either by copying or by moving. They
   are removed only from the front. The elements are never moved to a different
   memory location inside the buffer.

   Params:

       T = the type of the elements that will be stored on the block
       dtors = whether to execute destructors of elements upon removing them
*/
struct ReusableBlock(T, Flag!"dtors" dtors = Yes.dtors)
{
private:

    T * ptr_;           // The address of the beginning of the block
    size_t capacity_;   // Total elements that the block can hold
    size_t head_;       // The block index where element 0 is currently at
    size_t tail_;       // The block index where the next element will be placed at

public:

    /**
        Construct an object that will use the provided memory

        Params:

            buffer = the memory _buffer to use for the elements; the first few
                     bytes of the _buffer may not be used if its `.ptr` property
                     does not match `T.alignof`
    */
    this(ubyte[] buffer) @nogc pure scope @trusted
    {
        const extra = cast(ulong)buffer.ptr % T.alignof;
        if (extra) {
            // Align to the next aligned memory location
            buffer = buffer[T.alignof - extra .. $];
        }
        assert(cast(ulong)buffer.ptr % T.alignof == 0);

        this.ptr_ = cast(T*)(buffer.ptr);
        this.capacity_ = buffer.length / T.sizeof;
        this.head_ = 0;
        this.tail_ = 0;
    }

    /// Pointer to the beginning of the block
    inout(T) * ptr() inout @nogc pure @safe scope
    {
        return ptr_;
    }

    /// Total _capacity of the block
    size_t capacity() const @nogc pure @safe scope
    {
        return capacity_;
    }

    /// Number of elements the block currently has room for
    size_t freeCapacity() const @nogc pure @safe scope
    in (tail_ <= capacity_, blockError("Tail is ahead of capacity", this))
    {
        return capacity - tail_;
    }

    /// Current number of elements in the block
    size_t length() const @nogc pure @safe scope
    in (head_ <= tail_, blockError("Head is ahead of tail", this))
    {
        return tail_ - head_;
    }

    /// Whether the block has no elements at all
    bool empty() const @nogc pure @safe scope
    {
        return length == 0;
    }

    /**
        Add an _element after the existing elements; lvalues are copied, rvalues
        are moved.

        Params:

            element = the _element to add
    */
    void opOpAssign(string op, SourceT)(auto ref SourceT element)
    if (op == "~")
    in (freeCapacity, blockError("No room to append", this))
    {
        import std.traits : isCopyable;

        // This code is copied from std.array.Appender.put:
        auto elementUnqual = (() @trusted => & cast() element)();

        static if (__traits(isRef, element))
        {
            // We have an lvalue
            import core.lifetime : emplace;
            import std.format : format;

            static assert(isCopyable!SourceT,
                          format!"%s is not copyable"(SourceT.stringof));

            emplace(unqualPtr_ + tail_, *elementUnqual);
            ++tail_;
        }
        else
        {
            // We have an rvalue
            this.moveEmplace(element);
        }
    }

    /**
        Calls `~=` to copy the specified _element

        Params:

            element = the _element to copy
    */
    void copyBack(SourceT)(auto ref const(SourceT) element)
    {
        this ~= element;
    }

    /**
        Move the specified _element to the back of existing elements

        Params:

            element = the _element to move
    */
    void moveEmplace(SourceT)(ref SourceT element)
    in (freeCapacity, blockError("No room to moveEmplaceBack", this))
    {
        import core.lifetime : moveEmplace;

        // This code is copied from std.array.Appender.put:
        auto elementUnqual = (() @trusted => & cast() element)();

        moveEmplace(*elementUnqual, *(unqualPtr_ + tail_));
        ++tail_;
    }

    /**
        Construct a new element after the existing elements

        Params:

            args = the constructor arguments to use
    */
    void emplaceBack(Args...)(auto ref Args args)
    in (freeCapacity, blockError("No room to emplaceBack", this))
    {
        import core.lifetime : emplace;
        import std.format : format;

        static assert(__traits(compiles, emplace(ptr_, args)),
                      format!"%s is not emplacable from %s"(T.stringof, Args.stringof));

        emplace(ptr_ + tail_, args);
        ++tail_;
    }

    /**
        Return a reference to an element

        Params:

            index = the _index of the element to return
    */
    ref inout(T) opIndex(in size_t index) inout @nogc pure scope
    in (index < length, blockError("Invalid index", index, length))
    {
        return ptr_[head_ + index];
    }

    /**
        Remove elements from the head of the block. If `n == length`,
        `freeCapacity` will be equal to `capacity` after this call. Whether the
        destructors are called on the removed elements is determined by the
        `dtors` template parameter.

        Params:

            n = number of elements to remove
    */
    void removeFrontN(in size_t n) scope
    in (n <= length, blockError("Not enough elements to removeFrontN", n, this))
    {
        import std.traits : hasElaborateDestructor;

        static if (dtors && hasElaborateDestructor!T)
        {
            foreach_reverse(i; head_ .. head_ + n)
            {
                destroy(unqualPtr_[i]);
            }
        }

        if (n == length)
        {
            // No element left; start from the beginning
            head_ = 0;
            tail_ = 0;
        }
        else
        {
            head_ += n;
        }
    }

    /// The same as calling `this.removeFrontN(this.length)`
    void clear() scope
    {
        removeFrontN(length);
    }

    /// Number of elements in the block
    size_t opDollar() const @nogc pure @safe scope
    {
        return length;
    }

    /**
        A slice providing access _to the specified elements

        Params:

            from = the index of the first element of the slice
            to = the index of the element one beyond the last element of the slice
    */
    inout(T)[] opSlice(in size_t from, in size_t to) inout @nogc pure scope
    in (from <= to, blockError("Range begin is greater than end", from, to))
    in (to - from <= length, blockError("Range is too long", from, to, length))
    {
        return ptr[head_ + from .. head_ + to];
    }

    /// A slice to all elements; the same as `[0..$]`
    inout(T)[] opSlice() inout @nogc pure scope
    {
        return ptr[head_ .. tail_];
    }

    /// String representation of this object mostly for debugging
    void toString(scope void delegate(in char[]) sink) const scope
    {
        import std.format : formattedWrite;

        sink.formattedWrite!"%s @%s cap:%s elems:[%s..%s]"(
            T.stringof, ptr_, capacity_, head_, tail_);
    }

    private auto unqualPtr_() inout @nogc pure scope
    {
        import std.traits : Unqual;

        return cast(Unqual!T*)ptr_;
    }
}

///
unittest
{
    // Constructing a block on a piece of memory
    ubyte[100] buffer;
    auto b = ReusableBlock!int(buffer);

    // Depending on the alignment of the elements, the capacity may be less than
    // the requested amount
    assert(b.capacity <= buffer.length / int.sizeof);

    // Add 2 elements
    b ~= 0;
    b ~= 1;

    b.length.shouldBe(2);
    b[0].shouldBe(0);
    b[1].shouldBe(1);
    b.freeCapacity.shouldBe(b.capacity - 2);

    // Remove the first one
    b.removeFrontN(1);
    b.length.shouldBe(1);
    b[0].shouldBe(1);
    // Note that free capacity does not increase:
    b.freeCapacity.shouldBe(b.capacity - 2);

    // Remove all elements and reset the block
    b.clear();
    b.length.shouldBe(0);
    // This time all capacity is free
    b.freeCapacity.shouldBe(b.capacity);
}

version (unittest)
{
    import alid.test : shouldBe;

    private void assertInitialState(B)(B b)
    {
        import std.array : empty;

        b.capacity.shouldBe(b.freeCapacity);
        b.length.shouldBe(0);
        assert(b.empty);
        assert(b[0..$].empty);
        assert(b[].empty);
    }

    private auto makeValue(T)(int i)
    if (is (T == string))
    {
        import std.format : format;

        return format!"value_%s"(i);
    }

    private auto makeValue(T)(int i)
    if (!is (T == string))
    {
        return cast(T)i;
    }
}

unittest
{
    // Initializing with null buffer should not be an error

    auto b = ReusableBlock!int(null);
    assertInitialState(b);
}

unittest
{
    // Test with some fundamental types

    import std.array : empty;
    import std.meta : AliasSeq;

    void test(T)()
    {
        // Must be large enough to pass range tests below
        enum length = 40 * int.sizeof;
        ubyte[length] buffer;
        auto b = ReusableBlock!T(buffer);
        const cap = b.capacity;

        assertInitialState(b);

        // Add 1 element
        const e = makeValue!T(42);
        b ~= e;
        b.capacity.shouldBe(cap);
        b.freeCapacity.shouldBe(b.capacity - 1);
        b.length.shouldBe(1);
        assert(!b.empty);
        b[0].shouldBe(e);
        b[0..$].shouldBe([ e ]);
        b[].shouldBe([ e ]);

        // Drop the element
        b.removeFrontN(1);
        b.capacity.shouldBe(cap);

        // As all elements are removed, free capacity is increased automatically
        b.freeCapacity.shouldBe(b.capacity);
        b.length.shouldBe(0);
        assert(b.empty);
        assert(b[0..$].empty);
        assert(b[].empty);

        // Add another one
        const f = makeValue!T(43);
        b ~= f;
        b.capacity.shouldBe(cap);

        // Note that free capacity is reduced
        b.freeCapacity.shouldBe(b.capacity - 1);
        b.length.shouldBe(1);
        assert(!b.empty);
        b[0].shouldBe(f);
        b[0..$].shouldBe([ f ]);
        b[].shouldBe([ f ]);

        // Clearing should get us back to the beginning
        b.clear();
        assertInitialState(b);

        // Fill test
        T[] expected;
        foreach (i; 0 .. b.capacity)
        {
            import std.conv : to;

            assert(b.freeCapacity);
            const elem = makeValue!T(i.to!int);
            b ~= elem;
            expected ~= elem;
        }

        // Maximum capacity should not change
        b.capacity.shouldBe(cap);
        b.freeCapacity.shouldBe(0);
        b.length.shouldBe(b.capacity);
        assert(!b.empty);
        b[0..$].shouldBe(expected);
        b[].shouldBe(expected);

        b.removeFrontN(7);
        b.length.shouldBe(b.capacity - 7);
        b[].shouldBe(expected[7..$]);
        b[0..$].shouldBe(expected[7..$]);
        b[2..$-1].shouldBe(expected[9..$-1]);

        // Multiple clear calls
        b.clear();
        b.clear();
        assertInitialState(b);
    }

    alias Ts = AliasSeq!(int, const(int), double, immutable(double), ubyte, string);

    foreach (T; Ts)
    {
        test!T();
    }
}

unittest
{
    import std.meta : AliasSeq;

    struct S
    {
        int i = int.max;
        int j = int.max;

        this(int i, int j)
        {
            this.i = i;
            this.j = j;
        }

        this(this) @nogc pure @safe scope {}
    }

    void test(T)()
    {
        enum length = 400;
        auto buffer = new ubyte[length];
        auto b = ReusableBlock!T(buffer);

        b ~= T(2, 2);

        const n = T(7, 7);
        b~= n;

        b.copyBack(n);
        b.copyBack(T(8, 8));
        b.copyBack(n);

        auto m = T(3, 3);
        b.moveEmplace(m);
        assert(m == S.init);
    }

    alias Ts = AliasSeq!(S, const(S));

    foreach (T; Ts)
    {
        test!T();
    }
}

unittest
{
    // Destructors should be executed when requested

    import std.algorithm : each;
    import std.format : format;
    import std.range : iota;
    import std.typecons : No;

    void test(Flag!"dtors" dtors)(size_t elementCount, size_t expectedDtorCount)
    {
        static struct S
        {
            size_t * count = null;

            ~this()
            {
                if (count)
                {
                    ++(*count);
                }
            }
        }

        auto b = ReusableBlock!(S, dtors)(new ubyte[100]);

        size_t count = 0;
        assert(count == 0, "Invalid unittest");

        iota(elementCount).each!(_ => b ~= S(&count));
        b.removeFrontN(elementCount);

        count.shouldBe(expectedDtorCount);
    }

    test!(Yes.dtors)(10, 10);
    test!(No.dtors)(10, 0);
}

unittest
{
    // Emplace back from arguments
    struct S
    {
        int i;
        string s;
    }

    ubyte[100] buffer;
    auto b = ReusableBlock!S(buffer);

    static assert ( __traits(compiles, b.emplaceBack(42, "hello")));
    static assert (!__traits(compiles, b.emplaceBack("hello", 1.5)));
}
