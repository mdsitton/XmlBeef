using System;
using System.Collections;
using internal XmlBeef;

namespace XmlBeef;

/// The ID of an interned name (or namespace URI) in an XmlNameTable: equal names have equal IDs, so
/// comparisons are integer compares. 0 names nothing.
public struct XmlNameId : IHashable, IEquatable<XmlNameId>
{
	internal uint32 mValue;

	internal this(uint32 value)
	{
		mValue = value;
	}

	/// @brief Whether this names something (an ID is never 0).
	public bool IsValid => mValue != 0;
	/// @brief The ID that names nothing.
	public static XmlNameId None => default;
	/// @brief The ID as a number, for use as an index into side tables.
	public uint32 Value => mValue;

	public int GetHashCode() => (int)mValue;
	public bool Equals(XmlNameId other) => mValue == other.mValue;
	public static bool operator ==(XmlNameId lhs, XmlNameId rhs) => lhs.mValue == rhs.mValue;
	public static bool operator !=(XmlNameId lhs, XmlNameId rhs) => lhs.mValue != rhs.mValue;

	public override void ToString(String output)
	{
		mValue.ToString(output);
	}
}

/// Interns names and namespace URIs: each distinct string is stored once, in an arena whose text never
/// moves, and named by an XmlNameId. A qualified name's prefix and local part are interned on first
/// request and cached in its entry.
///
/// The hash is seeded per table (never global), and lookups compare lengths and hashes before bytes.
internal class XmlNameTable
{
	struct Entry
	{
		public char8* mPtr;
		public int32 mLength;
		public uint32 mHash;
		/// Offset of the first colon, -1 if none.
		public int32 mColon;
		/// 0: not computed yet; 1: a valid QName (NCName, or NCName:NCName); 2: not one.
		public uint8 mQName;
		public XmlNameId mPrefix;
		public XmlNameId mLocal;
	}

	List<Entry> mEntries ~ delete _;
	/// Open addressing, a power of two; each slot holds an ID (0: empty).
	uint32[] mSlots ~ delete _;
	BumpAllocator mText ~ delete _;
	uint64 mSeed;

	static uint64 sSeedCounter = 0x9E3779B97F4A7C15UL;

	public this()
	{
		mEntries = new .();
		mSlots = new uint32[64];
		mText = new BumpAllocator(.Ignore);
		sSeedCounter = sSeedCounter &* 6364136223846793005UL &+ 1442695040888963407UL;
		mSeed = sSeedCounter ^ (uint64)(int)Internal.UnsafeCastToPtr(this);
		mEntries.Add(default);
	}

	/// @brief The number of interned strings.
	public int Count => mEntries.Count - 1;

	/// @brief Forget every name (IDs from before become invalid), keeping the table's memory.
	public void Clear()
	{
		mEntries.Clear();
		mEntries.Add(default);
		Internal.MemSet(mSlots.Ptr, 0, mSlots.Count * sizeof(uint32));
		delete mText;
		mText = new BumpAllocator(.Ignore);
	}

	[Inline]
	uint32 Hash(char8* ptr, int length)
	{
		uint64 h = mSeed ^ ((uint64)length &* 0x100000001B3UL);
		int i = 0;
		while (i + 8 <= length)
		{
			uint64 word = ?;
			Internal.MemCpy(&word, ptr + i, 8);
			h = (h ^ word) &* 0x9E3779B97F4A7C15UL;
			h ^= h >> 29;
			i += 8;
		}
		while (i < length)
		{
			h = (h ^ (uint8)ptr[i]) &* 0x100000001B3UL;
			i++;
		}
		h ^= h >> 32;
		return (uint32)h;
	}

	/// @brief The ID of `text`, interning a copy of it if it is new.
	/// @param text The string.
	/// @return Its ID.
	public XmlNameId Intern(StringView text)
	{
		uint32 hash = Hash(text.Ptr, text.Length);
		uint32 mask = (uint32)mSlots.Count - 1;
		uint32 slot = hash & mask;
		while (true)
		{
			uint32 id = mSlots[slot];
			if (id == 0)
				break;
			ref Entry entry = ref mEntries[id];
			if (entry.mHash == hash && entry.mLength == text.Length && Internal.MemCmp(entry.mPtr, text.Ptr, text.Length) == 0)
				return .(id);
			slot = (slot + 1) & mask;
		}
		Entry entry = default;
		entry.mPtr = (char8*)mText.Alloc(Math.Max(text.Length, 1), 1);
		Internal.MemCpy(entry.mPtr, text.Ptr, text.Length);
		entry.mLength = (int32)text.Length;
		entry.mHash = hash;
		entry.mColon = (int32)text.IndexOf(':');
		uint32 newId = (uint32)mEntries.Count;
		mEntries.Add(entry);
		mSlots[slot] = newId;
		if (mEntries.Count * 2 > mSlots.Count)
			Rehash();
		return .(newId);
	}

	/// @brief The ID of `text` if it is interned.
	/// @param text The string.
	/// @return Its ID, or XmlNameId.None.
	public XmlNameId Find(StringView text)
	{
		uint32 hash = Hash(text.Ptr, text.Length);
		uint32 mask = (uint32)mSlots.Count - 1;
		uint32 slot = hash & mask;
		while (true)
		{
			uint32 id = mSlots[slot];
			if (id == 0)
				return .None;
			ref Entry entry = ref mEntries[id];
			if (entry.mHash == hash && entry.mLength == text.Length && Internal.MemCmp(entry.mPtr, text.Ptr, text.Length) == 0)
				return .(id);
			slot = (slot + 1) & mask;
		}
	}

	void Rehash()
	{
		uint32[] old = mSlots;
		mSlots = new uint32[old.Count * 2];
		uint32 mask = (uint32)mSlots.Count - 1;
		for (int id = 1; id < mEntries.Count; id++)
		{
			uint32 slot = mEntries[id].mHash & mask;
			while (mSlots[slot] != 0)
				slot = (slot + 1) & mask;
			mSlots[slot] = (uint32)id;
		}
		delete old;
	}

	/// @brief The text of `id` (empty for XmlNameId.None). Valid until the table is cleared.
	public StringView this[XmlNameId id]
	{
		[Inline]
		get
		{
			ref Entry entry = ref mEntries[id.mValue];
			return .(entry.mPtr, entry.mLength);
		}
	}

	/// @brief Whether the name contains a colon.
	[Inline]
	public bool HasColon(XmlNameId id)
	{
		return mEntries[id.mValue].mColon >= 0;
	}

	/// @brief Whether the name is a valid qualified name (Namespaces [7]): an NCName, or two joined by
	/// one colon. The name must already be a valid Name.
	public bool IsQName(XmlNameId id)
	{
		ref Entry entry = ref mEntries[id.mValue];
		if (entry.mQName == 0)
		{
			bool valid = true;
			if (entry.mColon >= 0)
			{
				StringView local = .(entry.mPtr + entry.mColon + 1, entry.mLength - entry.mColon - 1);
				valid = entry.mColon > 0 && !local.IsEmpty && local.IndexOf(':') < 0 && StartsWithNameStartChar(local);
			}
			entry.mQName = valid ? 1 : 2;
		}
		return entry.mQName == 1;
	}

	static bool StartsWithNameStartChar(StringView text)
	{
		return XmlChar.IsNameStartChar(XmlChar.Decode(text.Ptr, 0, let length));
	}

	/// @brief The prefix of a qualified name (None when it has no colon). Interned on first use.
	public XmlNameId PrefixOf(XmlNameId id)
	{
		ref Entry entry = ref mEntries[id.mValue];
		if (entry.mColon < 0)
			return .None;
		if (!entry.mPrefix.IsValid)
			SplitQName(id);
		return mEntries[id.mValue].mPrefix;
	}

	/// @brief The local part of a qualified name (the name itself when it has no colon). Interned on
	/// first use.
	public XmlNameId LocalOf(XmlNameId id)
	{
		ref Entry entry = ref mEntries[id.mValue];
		if (entry.mColon < 0)
			return id;
		if (!entry.mLocal.IsValid)
			SplitQName(id);
		return mEntries[id.mValue].mLocal;
	}

	void SplitQName(XmlNameId id)
	{
		// Interning may grow mEntries: take the parts first, store them after
		let entry = mEntries[id.mValue];
		let prefix = Intern(.(entry.mPtr, entry.mColon));
		let local = Intern(.(entry.mPtr + entry.mColon + 1, entry.mLength - entry.mColon - 1));
		ref Entry stored = ref mEntries[id.mValue];
		stored.mPrefix = prefix;
		stored.mLocal = local;
	}
}
