using System;
using System.Collections;
using internal XmlBeef;

namespace XmlBeef;

/// Plain bytes in chunks that never move, for text with one lifetime (a document's, a name table's, a
/// DTD's). `Reset` keeps every chunk for reuse, so reading document after document allocates nothing
/// once the arena has grown to the largest (the corlib BumpAllocator has no reset: deleting and
/// recreating one per small document was a measurable share of reading many small files).
internal class XmlTextArena
{
	List<uint8[]> mChunks ~ DeleteContainerAndItems!(_);
	/// The chunk being filled (-1: none yet since the last reset), where it is filled to, and its end.
	int mCurrent = -1;
	uint8* mNext;
	uint8* mLimit;
	int mFirstSize;

	public this(int firstChunkBytes = 4096)
	{
		mChunks = new .();
		mFirstSize = firstChunkBytes;
	}

	/// @brief `size` bytes (unaligned), valid until the arena is reset or deleted.
	[Inline]
	public char8* Alloc(int size)
	{
		if (mNext == null || (int)(void*)mLimit - (int)(void*)mNext < size)
			NextChunk(size);
		char8* p = (char8*)mNext;
		mNext += size;
		return p;
	}

	/// Moves to the next kept chunk that holds `size` bytes, or adds one (doubling, from mFirstSize up
	/// to 1 MB, or `size` if that is more).
	void NextChunk(int size)
	{
		while (++mCurrent < mChunks.Count)
		{
			let chunk = mChunks[mCurrent];
			if (chunk.Count >= size)
			{
				mNext = chunk.Ptr;
				mLimit = chunk.Ptr + chunk.Count;
				return;
			}
		}
		int chunkSize = mChunks.IsEmpty ? mFirstSize : Math.Min(mChunks.Back.Count * 2, 1 << 20);
		let chunk = new uint8[Math.Max(chunkSize, size)];
		mChunks.Add(chunk);
		mCurrent = mChunks.Count - 1;
		mNext = chunk.Ptr;
		mLimit = chunk.Ptr + chunk.Count;
	}

	/// @brief Forget everything allocated, keeping the chunks for the next use.
	public void Reset()
	{
		mCurrent = -1;
		mNext = null;
		mLimit = null;
	}

	/// @brief A copy of `text` in the arena.
	public StringView Copy(StringView text)
	{
		if (text.IsEmpty)
			return "";
		char8* bytes = Alloc(text.Length);
		Internal.MemCpy(bytes, text.Ptr, text.Length);
		return .(bytes, text.Length);
	}
}
