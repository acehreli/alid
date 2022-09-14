/**
   Implements an expanding circular buffer that places elements on an array of
   blocks.
 */

module alid.circularblocks;

import alid.errornogc;

private mixin NogcError!"circularblocks";

/**
   Represents an expanding circular buffer implemented as blocks of elements of
   `T`.

   The elements are added to the end, removed from the front, and are never
   moved around on the buffers.

   If user blocks are provided, those blocks are used for the elements until
   there is no more room on them, in which case new blocks are allocated from
   the GC heap.

   Params:

       T = the type of the elements to store
*/
struct CircularBlocks(T)
{
private:

    import alid.blockreusable : ReusableBlock;

    ReusableBlock!T[] blocks;    // Where elements are stored
    const(T*)[] userBlocks;      // The .ptr values of the user-provided blocks,
                                 // if any

    size_t heapBlockCapacity;    // The desired capacity for heap blocks

    size_t tailBlock = 0;        // The block new elements are being added to
    size_t capacity_ = 0;        // Current element capacity
    size_t length_ = 0;          // Total number of elements

    package size_t heapAllocations = 0;  // The number of times a block is
                                         // allocated from the GC heap

    @disable this();
    @disable this(this);

public:

    /**
        Construct an object without any user-provided blocks. All blocks will be
        allocated dynamically.

        Params:

            heapBlockCapacity = the minimum capacity desired for each heap
                                block; the actual capacity of each block may be
                                larger
    */
    this(in size_t heapBlockCapacity) nothrow pure @safe scope
    {
        this.heapBlockCapacity = heapBlockCapacity;
    }

    /**
        Construct an object that will use the provided buffer

        This constructor will allocate at least one additional heap block for a
        sliding window use case. Consider the constructor that takes array of
        arrays to prevent that allocation.

        Params:

            buffer = the buffer to use for the elements
    */
    this(ubyte[] buffer) nothrow pure scope
    {
        // Make a 1-element slice (without allocating memory) and dispatch to an
        // alternative constructor.
        this((&buffer)[0..1]);
    }

    /**
        Construct an object that will use the provided buffers

        This constructor will be friendly to the sliding window use case. As
        long as the window width remains less than or equal to the capacity of
        the shortest buffer, there should be no heap block allocation.

        This constructor picks the longest buffer's capacity to use for
        potential heap block allocations.

        Params:

            buffers = the _buffers to use for the elements
    */
    this(ubyte[][] buffers) nothrow pure @safe scope
    {
        this.userBlocks.reserve(buffers.length);

        foreach (buffer; buffers)
        {
            addInitialBlock(buffer);
        }
    }

    /// Ditto
    this(size_t N, size_t M)(ref ubyte[N][M] buffers) nothrow pure @safe scope
    {
        this.userBlocks.reserve(M);

        foreach (ref buffer; buffers)
        {
            addInitialBlock(buffer);
        }
    }

    private void addInitialBlock(ubyte[] buffer) nothrow pure @safe scope
    {
        import std.algorithm : max;
        import std.array : back;

        addExistingBlock_(buffer);
        userBlocks ~= blocks.back.ptr;

        this.heapBlockCapacity = max(this.heapBlockCapacity, blocks.back.capacity);
    }

    /**
       Clears all blocks in reverse order
     */
    ~this() scope
    {
        import std.algorithm : all, canFind, map;

        foreach_reverse (ref block; blocks)
        {
            block.clear();
        }

        // Check that we did not lose non-heap blocks
        assert(userBlocks.all!(pb => canFind(blocks.map!(b => b.ptr), pb)));
    }

    /// String representation of this object useful mostly for debugging
    void toString(scope void delegate(in char[]) sink) const scope
    {
        import std.algorithm : canFind, map;
        import std.format : format, formattedWrite;

        sink.formattedWrite!"cap:%s len:%s heapBlkCap:%s tail:%s added:%s\n"(
            capacity, length, heapBlockCapacity, tailBlock, heapAllocations);

        sink.formattedWrite!"occ: %s/%s\n"(
            heapBlockOccupancy.occupied, heapBlockOccupancy.total);

        sink.formattedWrite!"blocks (* -> user block):%-(\n %s%)\n"(
            blocks.map!(b => format!"%s%s"(canFind(userBlocks, b.ptr) ? "* " : "  ", b)));
    }

    /// Total element _capacity
    size_t capacity() const @nogc nothrow pure @safe scope
    {
        return capacity_;
    }

    /// Number of elements currently available
    size_t length() const @nogc nothrow pure @safe scope
    {
        return length_;
    }

    /**
        Append an _element

        Params:

            element = the _element to add; lvalues are copied, rvalues are moved
     */
    void opOpAssign(string op)(auto ref T element)
    if (op == "~")
    {
        ensureFreeSpace_();
        blocks[tailBlock] ~= element;
        ++length_;
    }

    /**
        Move an _element to the end

        Params:

            element = the _element to move
    */
    auto moveEmplace(ref T element) nothrow pure scope
    {
        ensureFreeSpace_();
        blocks[tailBlock].moveEmplace(element);
        ++length_;
    }

    /**
        Construct a new _element at the end

        Params:

            args = the constructor arguments to use
    */
    auto emplaceBack(Args...)(auto ref Args args)
    {
        ensureFreeSpace_();
        blocks[tailBlock].emplaceBack(args);
        ++length_;
    }

    /**
        Return a reference to an element

        Params:

            index = the _index of the element to return
    */
    ref inout(T) opIndex(size_t index) inout @nogc nothrow pure scope
    in (index < length,
        circularblocksError("Index is invalid for length", index, length))
    {
        // We don't want to use division because the blocks may have different
        // lengths; for example, the first block may have few elements currently
        // at an offset.
        foreach (block; blocks)
        {
            if (block.length > index)
            {
                return block[index];
            }

            index -= block.length;
        }

        assert(false, "If the pre-condition held, we should have returned early.");
    }

    /// Number of elements in the block
    size_t opDollar() const @nogc nothrow pure @safe scope
    {
        return length;
    }

    /**
        A range providing access _to the specified elements

        Params:

            from = the index of the first element of the range
            to = the index of the element one beyond the last element of the range
    */
    auto opSlice(in size_t from, in size_t to) const nothrow pure @safe scope
    in (from <= to, circularblocksError("Range begin is greater than end", from, to))
    in (to - from <= length, circularblocksError("Range is too long", from, to, length))
    {
        import std.algorithm : map;
        import std.range : iota;

        return iota(from, to).map!(i => this[i]);
    }

    /// A range to all elements; the same as `[0..$]`
    auto opSlice() const nothrow pure @safe scope
    {
        return this[0..$];
    }

    /**
        Remove elements from the head of the block

        Params:

            n = number of elements to remove
    */
    void removeFrontN(size_t n) scope
    in (length >= n, circularblocksError("Not enough elements to remove", n, length))
    {
        import std.algorithm : bringToFront;

        length_ -= n;

        // We don't want to use division because the blocks may have different
        // lengths; for example, the first block may have few elements currently
        // at an offset.
        size_t blockDropCount = 0;
        foreach (block; blocks)
        {
            if (n < block.length)
            {
                break;
            }

            n -= block.length;
            ++blockDropCount;
        }

        if (blockDropCount < blocks.length)
        {
            // This block will be the head block when others will be moved to
            // back. The elements here are the oldest, so they must be destroyed
            // first.
            blocks[blockDropCount].removeFrontN(n);
            tailBlock -= blockDropCount;
        }
        else
        {
            // All blocks will be dropped. This can only happen when the drop
            // count matched length.
            import alid.test : shouldBe;

            n.shouldBe(0);
            tailBlock = 0;
        }

        // Destroy elements of blocks that will go to the back
        foreach_reverse (b; 0 .. blockDropCount)
        {
            blocks[b].clear();
        }

        bringToFront(blocks[0..blockDropCount], blocks[blockDropCount..$]);
    }

    /**
       Total number of heap blocks and the number of those that are occupied by
       at least one element

       Returns: a tuple with two `size_t` members: `.total` and `.occupied`
    */
    auto heapBlockOccupancy() const @nogc nothrow pure @safe scope
    {
        import std.algorithm : canFind, count;
        import std.array : empty;
        import std.typecons : tuple;

        const occupied = blocks.count!(b => !b.empty && !canFind(userBlocks, b.ptr));
        const total = blocks.length - userBlocks.length;
        return tuple!("total", "occupied")(total, occupied);
    }

    /**
       Release all unoccupied heap blocks from the blocks array

       Return:

           number of blocks removed
    */
    size_t compact() @nogc nothrow pure @safe scope
    {
        import std.array : empty;
        import std.algorithm : canFind, map, remove, sum, SwapStrategy;

        const before = blocks.length;
        blocks = blocks.remove!(b => (b.empty && !canFind(userBlocks, b.ptr)),
                                SwapStrategy.unstable);
        const after = blocks.length;

        capacity_ = blocks.map!(b => b.capacity).sum;

        assert(before >= after);
        return before - after;
    }

private:

    void ensureFreeSpace_() nothrow pure @safe scope
    {
        import std.array : empty;

        if (blocks.empty)
        {
            import alid.test : shouldBe;

            addHeapBlock_();
            tailBlock.shouldBe(0);
        }
        else if (!blocks[tailBlock].freeCapacity)
        {
            ++tailBlock;

            if (tailBlock == blocks.length)
            {
                // Need a new block
                addHeapBlock_();
            }

            assert(blocks[tailBlock].empty);
        }
    }

    void addHeapBlock_() nothrow pure @trusted scope
    {
        import std.algorithm : max;

        // Using a T slice to guarantee correct alignment of Ts
        T[] tArr;
        tArr.reserve(heapBlockCapacity);

        // Use all extra capacity (tArr.capacity can be greater than
        // heapBlockCapacity)
        const ubyteCapacity = tArr.capacity * T.sizeof;
        auto arr = (cast(ubyte*)tArr.ptr)[0 .. ubyteCapacity];

        addExistingBlock_(arr);
        ++heapAllocations;
    }

    void addExistingBlock_(ubyte[] buffer) nothrow pure @safe scope
    {
        import std.array : back;

        blocks ~= ReusableBlock!T(buffer);
        capacity_ += blocks.back.capacity;
    }
}

///
unittest
{
    // This example starts with user-provided buffers. (It is possible to
    // provide a single buffer but that case would need to allocate at least one
    // heap buffer later e.g. in a sliding window use case.)

    enum size = 42;
    enum count = 2;
    ubyte[size][count] buffers;

    // Create a circular buffer of ints using those buffers
    auto c = CircularBlocks!int(buffers);

    // We can't be certain about total capacity because initial parts of the
    // buffers may not be used due to alignment requirements. At least make sure
    // the tests will be valid
    const initialCapacity = c.capacity;
    assert(initialCapacity > 0, "Invalid unittest");

    // Populate with some elements
    iota(initialCapacity).each!(i => c ~= i.to!int);

    // All capacity should be utilized at this point
    c.length.shouldBe(c.capacity);

    // As all elements are on provided buffers so far, there should be no heap
    // allocation yet
    c.heapBlockOccupancy.total.shouldBe(0);
    c.heapBlockOccupancy.occupied.shouldBe(0);

    // Adding one more element should allocate one heap block
    c ~= 42;
    c.heapBlockOccupancy.total.shouldBe(1);
    c.heapBlockOccupancy.occupied.shouldBe(1);
    assert(c.capacity > initialCapacity);

    // Remove all elements
    c.removeFrontN(c.length);
    c.length.shouldBe(0);
    c.heapBlockOccupancy.total.shouldBe(1);
    c.heapBlockOccupancy.occupied.shouldBe(0);

    // Release the unoccupied heap blocks
    c.compact();
    c.heapBlockOccupancy.total.shouldBe(0);
    c.heapBlockOccupancy.occupied.shouldBe(0);

    // Because we started with user buffers, the capacity should never be less
    // than initial capacity
    c.capacity.shouldBe(initialCapacity);
}

///
unittest
{
    // This example uses a single user-provided buffer. It is inevitable that
    // there will be at least one heap block allocation if more elements added
    // than the capacity of the user-provided buffer.

    ubyte[100] buffer;
    auto c = CircularBlocks!string(buffer[]);

    iota(c.capacity).each!(_ => c ~= "hi");
    c.length.shouldBe(c.capacity);

    // There should be no heap block allocation
    c.heapBlockOccupancy.total.shouldBe(0);
    c.heapBlockOccupancy.occupied.shouldBe(0);
}

///
unittest
{
    // This example does not start with any user-provided buffer
    const heapBlockCapacity = 100;
    auto c = CircularBlocks!double(heapBlockCapacity);

    // Due to lazy allocation, no heap block should be allocated yet
    c.capacity.shouldBe(0);

    // Adding elements should cause heap block allocations
    c ~= 1;
    assert(c.capacity != 0);
    c.heapBlockOccupancy.total.shouldBe(1);
    c.heapBlockOccupancy.occupied.shouldBe(1);
}

///
unittest
{
    // When user-provided buffers are sufficiently large for a sliding window of
    // elements, no heap block should be allocated

    ubyte[64][2] buffers;
    auto c = CircularBlocks!int(buffers);
    assert(c.capacity != 0);

    // Start with some elements filling half the capacity
    iota(c.capacity / 2).each!(i => c ~= i.to!int);

    // Use the rest of the capacity as the width of a sliding window
    const windowWidth = c.capacity - c.length;

    // Add and remove equal number of elements for many number of times
    foreach (i; 0 .. 117)
    {
        iota(windowWidth).each!(i => c ~= i.to!int);
        // Prove that buffer is completely full after the additions
        c.length.shouldBe(c.capacity);
        c.removeFrontN(windowWidth);
    }

    // No heap block should have been allocated
    c.heapBlockOccupancy.total.shouldBe(0);
}


version (unittest)
{
    import alid.test : shouldBe;
    import std.algorithm : each, map;
    import std.array : array;
    import std.conv : to;
    import std.range : iota;
}

unittest
{
    // Test const and immutable types are usable

    import std.meta : AliasSeq;

    void test(T)(in T value)
    {
        auto c = CircularBlocks!T(100);
        c ~= value;
        c[0].shouldBe(value);
        c.removeFrontN(1);
        c.length.shouldBe(0);
    }

    struct S
    {
        string s;
    }

    alias Ts = AliasSeq!(const(int), 42,
                         immutable(double), 1.5,
                         const(S), S("hello"));

    static foreach (i; 0 .. Ts.length)
    {
        static if (i % 2 == 0)
        {
            test!(Ts[i])(Ts[i+1]);
        }
    }
}

unittest
{
    // Test the range interface

    import std.algorithm : each, equal;

    auto c = CircularBlocks!size_t(1024);

    enum begin = size_t(0);
    enum end = size_t(1000);
    iota(begin, end).each!(i => c ~= i);

    enum dropped = size_t(10);
    c.removeFrontN(dropped);

    assert(end > dropped);

    c[0..$].length.shouldBe(end - dropped);
    assert(c[].equal(iota(dropped, end)));
    assert(c[0..$].equal(iota(dropped, end)));
}

unittest
{
    // The string representation

    auto c = CircularBlocks!string(new ubyte[10]).to!string;
}

unittest
{
    // moveEmplace tests

    static struct S
    {
        string msg = "initial value";

        // Needed for destroy() to set to the .init value
        ~this() {}
    }

    auto s = S("hello");
    assert(s.msg);

    auto c = CircularBlocks!S(10);
    c.moveEmplace(s);
    c.length.shouldBe(1);
    c[].front.msg.shouldBe("hello");
    s.msg.shouldBe("initial value");
}
