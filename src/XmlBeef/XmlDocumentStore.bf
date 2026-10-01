using System;
using internal XmlBeef;

namespace XmlBeef;

/// @brief Owns the text of a document (its copy of the input, decoded values, the DOCTYPE's identifiers
/// and internal subset) in an arena released together when the store is reset or destroyed. (Names are
/// in the document's XmlNameTable.)
///
/// Reset keeps the arena's chunks, so reading into a document again reuses the previous document's
/// memory: freeing it instead lets glibc trim the heap, and the next parse page-faults every page back
/// in (TomlBeef measured up to 40% of parse time on large inputs). The store holds at most what the
/// largest document read needed.
internal class XmlDocumentStore
{
	XmlTextArena mText ~ delete _;

	/// @brief Create a store whose first chunk holds `firstChunkBytes` (later ones double, to 1 MB).
	/// @param firstChunkBytes The first chunk's size: 64 KiB for reading, the exact size when compacting.
	public this(int firstChunkBytes = 64 * 1024)
	{
		mText = new XmlTextArena(firstChunkBytes);
	}

	/// @brief The arena (for its sizes).
	public XmlTextArena Text => mText;

	/// @brief Copy text into the arena.
	/// @param text The text to copy.
	/// @return A view of the store-owned copy.
	[Inline]
	public StringView NewText(StringView text)
	{
		return mText.Copy(text);
	}

	/// @brief Release all text, keeping the arena's memory for the next document.
	public void Reset()
	{
		mText.Reset();
	}

	/// @brief Release all text and free the arena's memory.
	public void Release()
	{
		mText.Release();
	}
}
