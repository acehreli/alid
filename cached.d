/**
   Implements a range algorithm that caches element values turns InputRangess to
   RandomAccessRanges.
 */

module alid.cached;

import alid.errornogc : NogcError;
import alid.circularblocks : CircularBlocks;
import core.memory : pageSize;
import std.range : ElementType;

/**
    A _range algorithm that caches the elements of a _range by evaluating them
    only once.

    As a natural benefit of caching, the returned _range is a `ForwardRange`
    even if the source _range is an `InputRange`. Although the returned _range
    provides `opIndex`, it is a `RandomAccessRange` only if the source _range
    `hasLength`.

    The version that takes buffers may never need to allocate memory if the
    number of elements never exceed the capacity of the underlying
    `CircularBlocks`. (See `CircularBlocks`.)

    Params:

        range = the source _range to cache elements of

        heapBlockCapacity = the minimum capacity to use for `CircularBlocks`,
                            which is used as storage for the _cached elements;
                            the default value attemps to use one page of memory

        buffers = the _buffers to be used by the `CircularBlocks` member

    Bugs:

        Although `opIndex` is provided, `isRandomAccessRange` produces `false`
        because this implementation is not a `BidirectionalRange` at this time.

    Todo:

        Add `opApplyReverse` support and `BidirectionalRange` functions

*/
auto cached(R)(R range, size_t heapBlockCapacity = pageSize / ElementType!R.sizeof)
{
    // Makes a new ElementCache object that will be kept alive collectively with
    // the slices that it produces, first of which is returned.

    if (heapBlockCapacity == 0)
    {
        heapBlockCapacity = 100;
    }

    auto elements = CircularBlocks!(ElementType!R)(heapBlockCapacity);
    auto theCacheObject = new ElementCache!R(range, elements, heapBlockCapacity);

    // This first slice starts with offset 0
    enum elementOffset = 0;
    return theCacheObject.makeSlice(elementOffset);
}

/// Ditto
auto cached(R, size_t N, size_t M)(R range, ref ubyte[N][M] buffers)
{
    // Makes a new ElementCache object that will be kept alive collectively with
    // the slices that it produces, first of which is returned.

    auto elements = CircularBlocks!(ElementType!R)(buffers);
    enum heapBlockCapacity = N;
    auto theCacheObject = new ElementCache!R(range, elements, heapBlockCapacity);

    enum elementOffset = 0;
    return theCacheObject.makeSlice(elementOffset);
}

///
unittest
{
    // In the following typical usage, even though `slide(2)` would visit most
    // elements more than once, `cached` guarantees that the lambda function
    // executed by `map` will be executed only once per range element.

    auto r = iota(4)
             .map!(i => i * i)    // [0, 1, 4, 9]
             .cached
             .slide(2)
             .array;

    // There are 3 sliding windows of width 2 over 4 elements
    r.length.shouldBe(3);
    assert(r[0].equal([0, 1]));
    assert(r[1].equal([1, 4]));
    assert(r[2].equal([4, 9]));
}

///
unittest
{
    // Random access over an InputRange

    import std.algorithm : splitter;
    import std.range : popFrontN;

    auto lines = "monday,tuesday,wednesday,thursday";

    auto s = lines.splitter(',');
    auto c = s.cached;

    // The source range does not provide random access:
    static assert(!__traits(compiles, s[0]));

    // The cached range does:
    assert(c[2] == "wednesday");
    assert(c[1] == "tuesday");

    c.popFrontN(3);

    // Now index 0 is another element
    assert(c[0] == "thursday");
}

///
unittest
{
    // This version uses an existing buffer. It may never need to allocate
    // additional heap memory.

    ubyte[1024][2] buffers;
    auto r = iota(4)
             .map!(i => i * i)
             .cached(buffers)    // Will use the provided buffers
             .slide(2)
             .array;

    r.length.shouldBe(3);
}

private mixin NogcError!"cached";

/*
  This is the implementation of the actual cache, elements of which will be
  shared by potentially multiple CachedRange ranges.
*/
private struct ElementCache(R)
{
    import std.array : empty;
    import std.range : hasLength, ElementType;
    import std.traits : isUnsigned;

    // Useful aliases and values
    alias ET = ElementType!R;
    alias invalidSliceOffset = CachedRange!ElementCache.invalidSliceOffset;
    enum rangeHasLength = hasLength!R;

    R range;                       // The source range
    CircularBlocks!ET elements;    // The cached elements
    size_t[] sliceOffsets;         // The beginning indexes of slices into 'elements'

    size_t liveSliceCount;         // The number of slices that are still being used
    size_t dropLeadingAttempts;    // The number of times we considered but did
                                   // not go with dropping leading elements

    size_t minElementsToDrop;      // The number of elements we consider large
                                   // enough to consider for dropping

    Stats stats_;

    @disable this(this);
    @disable this(ref const(typeof(this)));

    this(R range, ref CircularBlocks!ET elements, size_t heapBlockCapacity)
    {
        import std.algorithm : move;

        this.range = range;
        this.elements = move(elements);

        // Make it the same as heap capacity because it is likely that the
        // underlying circular buffer will keep the elements alive below this
        // figure anyway.
        this.minElementsToDrop = heapBlockCapacity;
    }

    Stats stats() const @nogc nothrow pure @safe scope
    {
        Stats result = stats_;
        // Unlike other statistics figures, this value is not kept up-do-date by
        // us
        result.heapAllocations = elements.heapAllocations;
        return result;
    }

    // Whether the parameter is valid as a slice id
    bool isValidId_(in size_t id) const @nogc nothrow pure @safe scope
    {
        return id < sliceOffsets.length;
    }

    // mixin string for throwing an Error
    enum idError_ = `cachedError("Invalid id", id)`;

    // Whether the specified slice is empty
    bool emptyOf(in size_t id) pure scope
    in (isValidId_(id), mixin (idError_))
    {
        if (!range.empty) {
            expandAsNeeded(id, 1);
        }

        return (sliceOffsets[id] == elements.length) && range.empty;
    }

    // The front element of the specified slice
    auto frontOf(in size_t id) scope
    in (isValidId_(id), mixin (idError_))
    {
        expandAsNeeded(id, 1);
        return elements[sliceOffsets[id]];
    }

    // Pop an element from the specified slice
    void popFrontOf(in size_t id) @nogc nothrow pure @safe scope
    in (isValidId_(id), mixin (idError_))
    {
        // Trivially increment the offset.
        ++sliceOffsets[id];

        if (sliceOffsets[id] >= minElementsToDrop) {
            /*
              This slice has popped enough elements for us to consider dropping
              leading elements. But we don't want to rush to it yet because even
              determining whether there are unused elements or not incur some
              cost.

              We will apply the heuristic rule of ensuring this condition has
              been seen at least as many times as there are live slices. (Even a
              single slice is sufficient to hold on to the leading elements.)
            */
            ++dropLeadingAttempts;

            if (dropLeadingAttempts >= liveSliceCount) {
                // We waited long enough
                dropLeadingAttempts = 0;
                const minIndex = unreferencedLeadingElements();

                if (minIndex) {
                    // There are leading elements that are not being used
                    // anymore
                    dropLeadingElements(minIndex);

                    // TODO: Commenting out for now because we can't be sure of
                    //       usage patterns to decide to remove blocks from the
                    //       underlying storage. (See a related 'version' in one
                    //       of the unittest blocks.)
                    version (RUN_COMPACTION)
                    {
                    // Since we've dropped elements, let's also consider
                    // dropping unused blocks from the underlying circular
                    // buffer.
                    const occupancy = elements.heapBlockOccupancy;

                    if (occupancy.occupied &&
                        (occupancy.total > occupancy.occupied * 4)) {
                        ++stats_.compactionRuns;
                        const removedBlocks = elements.compact();
                        stats_.removedBlocks += removedBlocks;
                    }
                    } // version (none)
                }
            }
        }
    }

    // The specified element (index) of the specified slice (id).
    auto getElementOf(in size_t id, in size_t index) scope
    in (isValidId_(id), mixin (idError_))
    {
        expandAsNeeded(id, index + 1);
        return elements[sliceOffsets[id] + index];
    }

    // Make and return a new range object that has the same beginning index as
    // the specified slice
    auto saveOf(in size_t id) nothrow pure scope
    in (isValidId_(id), mixin (idError_))
    {
        return makeSlice(sliceOffsets[id]);
    }

    static if (rangeHasLength)
    {
        // The length of the specified slice
        auto lengthOf(in size_t id) @nogc nothrow pure @safe scope
        in (isValidId_(id), mixin (idError_))
        {
            return range.length + elements.length - sliceOffsets[id];
        }
    }

    // Create and return a RefCounted!CachedRange that initially references all
    // currently cached elements beginning from the specified offset (element
    // index)
    auto makeSlice(in size_t offset)
    {
        import std.algorithm : find, move;
        import std.typecons : refCounted;

        // Find an unused spot in the slice offsets array.
        auto found = sliceOffsets.find(invalidSliceOffset);
        const id = sliceOffsets.length - found.length;

        if (id == sliceOffsets.length)
        {
            // There is no unused spot; add one.
            sliceOffsets ~= offset;
        }
        else
        {
            sliceOffsets[id] = offset;
        }

        ++liveSliceCount;

        // Return a reference counted object so that its destructor will
        // "unregister" it by removing it from the list of slices.
        auto slice = CachedRange!ElementCache(&this, id);
        return refCounted(move(slice));
    }

    // Remove the specified slice; it does not own any element anymore
    void removeSlice(in size_t id)
    in (isValidId_(id), mixin (idError_))
    {
        sliceOffsets[id] = invalidSliceOffset;
        --liveSliceCount;
    }

    // Determine the number of leading elements that are not being referenced
    // (used) by any slice
    size_t unreferencedLeadingElements() @nogc nothrow pure @safe scope
    {
        auto minOffset = size_t.max;

        foreach (offset; sliceOffsets)
        {
            // There is no reason to continue because 0 is the absolute minimum
            // for unsigned types.
            if (offset == minOffset.min)
            {
                return offset;
            }

            if (offset < minOffset)
            {
                minOffset = offset;
            }
        }

        return minOffset;
    }

    // Drop specified number of leading elements from the cache
    void dropLeadingElements(size_t n) @nogc nothrow pure @safe scope
    {
        import std.algorithm : each, filter;

        // Drop the unreferenced elements
        elements.removeFrontN(n);

        // Adjust the starting indexes of all slices accordingly.
        sliceOffsets
            .filter!((ref i) => i != invalidSliceOffset)
            .each!((ref i) => i -= n);

        ++stats_.leadingDropRuns;
        stats_.droppedElements += n;
    }

    // Ensure that the specified slice has elements as needed
    void expandAsNeeded(in size_t id, in size_t needed) scope
    in (isValidId_(id), mixin (idError_))
    in (sliceOffsets[id] <= elements.length,
        cachedError("Invalid element index", id, sliceOffsets[id], elements.length))
    {
        // expandCache may change both elements and sliceOffsets.
        while ((elements.length - sliceOffsets[id]) < needed)
        {
            expandCache();
        }
    }

    // Expand the element cache by adding one more element from the source range
    void expandCache() scope
    in (!range.empty)
    {
        import std.range : front, popFront;

        // Transfer one element from the source range to the cache
        elements.emplaceBack(range.front);
        range.popFront();
    }
}

/**
   Statistics about the operation of `ElementCache` as well as the underlying
   `CircularBlocks` that it uses for element storage.
*/
static struct Stats
{
    /// Number of blocks allocated from the heap by the underlying
    /// `CircularBlocks` storage
    size_t heapAllocations;

    /// Number of times the algorithm for dropping leading elements is executed
    size_t leadingDropRuns;

    /// Number of leading elements dropped
    size_t droppedElements;

    /// Number of times `CircularBlocks.compact` is executed
    size_t compactionRuns;

    /// Number of blocks removed due to compaction
    size_t removedBlocks;

    void toString(scope void delegate(in char[]) sink) const scope
    {
        import std.format : formattedWrite;

        sink.formattedWrite!"heap blocks allocated           : %s\n"(heapAllocations);
        sink.formattedWrite!"leading-element-drop executions : %s\n"(leadingDropRuns);
        sink.formattedWrite!"total elements dropped          : %s\n"(droppedElements);
        sink.formattedWrite!"block compactions executions    : %s\n"(compactionRuns);
        sink.formattedWrite!"blocks removed due to compaction: %s\n"(removedBlocks);
    }
}

version (unittest)
{
    import alid.test : shouldBe;
    import std.algorithm : equal, filter, map;
    import std.array : array;
    import std.range : iota, slide;
}

/**
    Represents a `ForwardRange` (and a `RandomAccessRange` when possible) over
    the cached elements of a source range. Provides the range algorithm
    `length()` only if the source range does so.

    Params:

        EC = the template instance of the `ElementCache` template that this
             range provides access to the elements of. The users are expected to
             call one of the `cached` functions, which sets this parameter
             automatically.
*/
//  All pre-condition checks are handled by dispatched ElementCache member functions.
struct CachedRange(EC)
{
private:

    EC * elementCache;
    size_t id = size_t.max;

    enum invalidSliceOffset = size_t.max;

    // We can't allow copying objects of this type because they are intended to
    // be reference counted. The users must call save() instead.
    @disable this(this);

    // Takes the ElementCache object that this is a slice of, and the assigned
    // id of this slice
    this(EC * elementCache, in size_t id)
    {
        this.elementCache = elementCache;
        this.id = id;
    }

public:

    /**
       Unregisters this slices from the actual `ElementCache` storage.
     */
    ~this() @nogc nothrow pure @safe scope
    {
        // Prevent running on an .init state, which move() leaves behind
        if (elementCache !is null)
        {
            elementCache.removeSlice(id);
        }
    }

    /**
       Return statistics about the operation of `ElementCache` as well as the
       underlying `CircularBlocks` that it uses for element storage
    */
    Stats stats() const @nogc nothrow pure @safe scope
    {
        return elementCache.stats;
    }

    /**
        Support for `foreach` loops
     */
    // This is needed to support foreach iteration because although
    // RefCounted!CachedRange implicitly converts to CachedRange, which would be
    // a range, the result gets copied to the foreach loop. Unfortunately, this
    // type does not allow copying so we have to support foreach iteration
    // explicitly here.
    int opApply(int delegate(ref EC.ET) func) scope
    {
        while(!empty)
        {
            auto f = front;
            int result = func(f);
            if (result)
            {
                return result;
            }
            popFront();
        }

        return 0;
    }

    /// Ditto
    int opApply(int delegate(ref size_t, ref EC.ET) func) scope
    {
        size_t counter;
        while(!empty)
        {
            auto f = front;
            int result = func(counter, f);
            if (result)
            {
                return result;
            }
            popFront();
            ++counter;
        }

        return 0;
    }

    // InputRange functions

    /// Whether the range is empty
    auto empty() pure scope
    {
        return elementCache.emptyOf(id);
    }

    /// The front element of the range
    auto front() scope
    {
        return elementCache.frontOf(id);
    }

    /// Remove the front element from the range
    void popFront() @nogc nothrow pure @safe scope
    {
        elementCache.popFrontOf(id);
    }

    // ForwardRange function

    /// Make and return a new `ForwardRange` object that is the equivalent of
    /// this range object
    auto save() nothrow pure scope
    {
        return elementCache.saveOf(id);
    }

    // RandomAccessRange function

    /**
        Return a reference to an element

        The algorithmic complexity of this function is amortized *O(1)* because
        it might need to cache elements between the currently available last
        element and the element about to be accessed with the specified index.

        Params:

            index = the _index of the element to return
    */
    auto opIndex(in size_t index) scope
    {
        return elementCache.getElementOf(id, index);
    }

    // An optional length

    static if (EC.rangeHasLength)
    {
        /**
            Number of elements of this range

            This function is available only if the source range provides it.
        */
        auto length() @nogc nothrow pure @safe scope
        {
            return elementCache.lengthOf(id);
        }
    }
}

unittest
{
    // Should compile and work with D arrays

    assert([1, 2].cached.equal([1, 2]));
}

unittest
{
    // 0 as heapBlockCapacity should work

    auto r = iota(10).cached(0);
    r[5].shouldBe(5);
    assert(r.equal(iota(10)));
}

unittest
{
    // InputRange, ForwardRange, save, and .length() tests

    import std.range : take;

    auto r = iota(1, 11).cached;
    assert(!r.empty);
    r.front.shouldBe(1);
    r.length.shouldBe(10);

    r.popFront();
    assert(!r.empty);
    r.front.shouldBe(2);
    r.length.shouldBe(9);

    assert(r.take(4).equal(iota(2, 6)));
    assert(!r.empty);
    r.front.shouldBe(6);
    r.length.shouldBe(5);

    auto r2 = r.save();
    assert(r2.equal(iota(6, 11)));
    assert(r2.empty);
    r2.length.shouldBe(0);

    assert(r.equal(iota(6, 11)));
    assert(r.empty);
    r.length.shouldBe(0);
}

unittest
{
    // Iteration tests

    import std.traits : isIterable;

    enum begin = 1;
    auto r = iota(begin, 11).cached;
    static assert (isIterable!(typeof(r)));

    auto r2 = r.save();

    foreach (e; r)
    {
        if (e == 3)
        {
            break;
        }
    }
    r.front.shouldBe(3);

    // Fully consume for code coverage
    foreach (e; r)
    {
    }
    assert(r.empty);

    foreach (i, e; r2)
    {
        e.shouldBe(i + begin);

        if (e == 7)
        {
            break;
        }
    }
    r2.front.shouldBe(7);

    // Fully consume for code coverage
    foreach (i, e; r2)
    {
    }
    assert(r2.empty);
}

unittest
{
    // RandomAccessRange tests

    import std.algorithm : each;

    auto r = iota(0, 7).cached;
    iota(5, 0, -1).each!(i => r[i].shouldBe(i));
}

unittest
{
    // hasLength tests

    import std.range : hasLength;

    {
        auto r = iota(10).cached;
        static assert (hasLength!(typeof(r)));
    }
    {
        auto r = iota(10).filter!(i => i % 2).cached;
        static assert (!hasLength!(typeof(r)));
    }
}

unittest
{
    // Although it is discouraged to have side-effects in a map lambda, let's test
    // with such a map to prove that the lambda is executed only once per element.

    import std.algorithm : find;

    enum n = 42;
    enum nonExistingValue = n + 1;
    size_t counter = 0;

    // Ensure all operations will be evaluated by searching for nonExistingValue
    // in all elements of all sliding window ranges.
    auto found = iota(n)
                 .map!((i)
                       {
                           ++counter;
                           return i;
                       })
                 .cached
                 .slide(3)
                 .find!(window => !window.find(nonExistingValue).empty);

    // Validate the test
    assert(found.empty);

    counter.shouldBe(n);
}

unittest
{
    // Test that map expressions used by zip are cached as filter works on them.

    import std.array : array;
    import std.range : zip;

    enum n = 10;
    size_t count;

    auto r = zip(iota(0, n)
                 .map!(_ => ++count))
             .cached
             .filter!(t => t[0] == t[0])  // Normally, multiple execution
             .array;

    count.shouldBe(n);
}

unittest
{
    // Out-of-bounds access should throw

    import std.exception : assertThrown;

    assertThrown!Error(
        {
            auto r = iota(5).cached;
            int result = 0;

            // More access than elements available
            foreach (i; 0 .. 10)
            {
                result += r.front;
                r.popFront();
            }
        }());
}

unittest
{
    // The following is the code that exposed a difference between Rust's
    // tuple_window and D's slide. tuple_window uses once() in its
    // implementation so the generator lambda is executed only once per
    // element. D's slide calls map's front multiple times. .cached is supposed
    // to prevent that.

    import std.array : array;

    static struct Data
    {
        int * ptr;
        size_t capacity;
    }

    enum n = 1_000;

    int[] v;

    auto r = iota(n)
             .map!((i)
                   {
                       v ~= i;
                       return Data(v.ptr, v.capacity);
                   })
             .cached    // The lambda should be executed once per object
             .slide(2)  // [0,1], [1,2], [2,3], etc.
             .filter!((t)
                      {
                          const prev = t.front.ptr;
                          t.popFront();
                          const curr = t.front.ptr;
                          return prev != curr;
                      })
             .map!(t => t.front.capacity)
             .array;

    v.length.shouldBe(n);
}

unittest
{
    // A single slice should be sufficient to keep all elements alive

    import std.algorithm : each;
    import std.conv : to;

    // Picking a large number of elements along with very small capacity to
    // cause at least one consideration of dropping the front elements
    enum n = 10_000;
    enum heapBlockCapacity = 5;

    auto r = iota(n).cached(1000);

    {
        void consume(A)(ref A a)
        {
            while(!a.empty)
            {
                a.popFront();
            }
        }

        // Create saved states of the range
        auto saveds = iota(4).map!(_ => r.save()).array;

        // This operation will ensure populating the element cache
        consume(r);

        // No leading element should have been dropped
        assert(saveds[0].length == n);

        // Consume all saved states but one
        foreach (ref s; saveds[1..$])
        {
            consume(s);
        }

        // Still, no leading element should have been dropped
        assert(saveds[0].length == n);

        // Finally, there should be dropping of leading elements
        consume(saveds[0]);
    }

    // We expect non-zero figures
    const stats = r.stats;
    assert(stats.heapAllocations);
    assert(stats.leadingDropRuns);
    assert(stats.droppedElements);
    version (RUN_COMPACTION)
    {
        assert(stats.compactionRuns);
        assert(stats.removedBlocks);
    } else {
        assert(stats.compactionRuns == 0);
        assert(stats.removedBlocks == 0);
    }

    stats.to!string;
}
