using System;
using internal XmlBeef;

namespace XmlBeef;

/// A growable array of values for the reader's per-event lists (open elements, namespace bindings, a
/// tag's attributes): `Add`, `PopBack`, `Back` and the indexer are inlined, which corlib's List.Add
/// and Count setter are not (each showed up in the event pass's profile).
internal class XmlStack<T> where T : struct
{
	T[] mItems ~ delete _;
	int mCount;

	public this(int capacity = 16)
	{
		mItems = new T[capacity];
	}

	/// The number of items; setting it lower (never higher) drops the items above.
	public int Count
	{
		[Inline]
		get => mCount;
		[Inline]
		set => mCount = value;
	}

	public bool IsEmpty
	{
		[Inline]
		get => mCount == 0;
	}

	[Inline]
	public void Add(T item)
	{
		if (mCount == mItems.Count)
			Grow();
		mItems[mCount++] = item;
	}

	/// Adds a default item and returns it.
	[Inline]
	public ref T AddDefault()
	{
		if (mCount == mItems.Count)
			Grow();
		mItems[mCount] = default;
		return ref mItems[mCount++];
	}

	/// Adds `count` items left uninitialized and returns the first.
	[Inline]
	public T* GrowUninitialized(int count)
	{
		if (mCount + count > mItems.Count)
			Reserve(mCount + count);
		// One past the end when `count` is 0 and the array is full: a pointer, not an index
		T* first = mItems.Ptr + mCount;
		mCount += count;
		return first;
	}

	/// Makes room for at least `capacity` items.
	public void Reserve(int capacity)
	{
		if (capacity <= mItems.Count)
			return;
		T[] old = mItems;
		mItems = new T[Math.Max(capacity, old.Count * 2)];
		Internal.MemCpy(mItems.Ptr, old.Ptr, mCount * strideof(T), alignof(T));
		delete old;
	}

	void Grow()
	{
		Reserve(mItems.Count * 2);
	}

	[Inline]
	public T PopBack()
	{
		return mItems[--mCount];
	}

	public ref T Back
	{
		[Inline]
		get => ref mItems[mCount - 1];
	}

	public ref T this[int index]
	{
		[Inline]
		get => ref mItems[index];
	}

	[Inline]
	public void Clear()
	{
		mCount = 0;
	}

	/// The items as a span (valid until the stack changes).
	public Span<T> Span => .(mItems.Ptr, mCount);
}
