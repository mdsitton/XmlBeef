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
	/// Open addressing, a power of two; each slot holds an ID in its low half and the name's hash in its
	/// high half (0: empty), so a probe that misses does not read the entry.
	uint64[] mSlots ~ delete _;
	XmlTextArena mText ~ delete _;
	uint64 mSeed;

	static uint64 sSeedCounter = 0x9E3779B97F4A7C15UL;

	/// The names every table holds, at these IDs, through every Clear (the namespace rules need them).
	public const XmlNameId cXml = .(1);
	public const XmlNameId cXmlns = .(2);
	public const XmlNameId cXmlNamespace = .(3);
	public const XmlNameId cXmlnsNamespace = .(4);
	/// @brief The namespace the `xml` prefix is bound to, always.
	public const String XmlNamespaceUri = "http://www.w3.org/XML/1998/namespace";
	/// @brief The namespace of namespace declarations (`xmlns`, `xmlns:p`).
	public const String XmlnsNamespaceUri = "http://www.w3.org/2000/xmlns/";
	const int cPredefined = 4;
	static StringView[cPredefined] sPredefined = .("xml", "xmlns", "http://www.w3.org/XML/1998/namespace", "http://www.w3.org/2000/xmlns/");

	public this()
	{
		mEntries = new .();
		mSlots = new uint64[64];
		mText = new XmlTextArena();
		sSeedCounter = sSeedCounter &* 6364136223846793005UL &+ 1442695040888963407UL;
		mSeed = sSeedCounter ^ (uint64)(int)Internal.UnsafeCastToPtr(this);
		mEntries.Add(default);
		AddPredefined();
	}

	/// Interns the predefined names, whose text is static (not in the arena, which Clear resets).
	void AddPredefined()
	{
		for (let name in sPredefined)
		{
			uint32 hash = Hash(name.Ptr, name.Length);
			uint32 mask = (uint32)mSlots.Count - 1;
			uint32 slot = hash & mask;
			while (mSlots[slot] != 0)
				slot = (slot + 1) & mask;
			Entry entry = default;
			entry.mPtr = name.Ptr;
			entry.mLength = (int32)name.Length;
			entry.mHash = hash;
			entry.mColon = -1;
			uint32 id = (uint32)mEntries.Count;
			mEntries.Add(entry);
			mSlots[slot] = ((uint64)hash << 32) | id;
		}
	}

	/// @brief The number of interned strings.
	public int Count => mEntries.Count - 1;

	/// @brief Forget every name but the predefined ones (IDs from before become invalid), keeping the
	/// table's memory.
	public void Clear()
	{
		if (mEntries.Count == 1 + cPredefined)
			return;
		mEntries.Count = 1;
		Internal.MemSet(mSlots.Ptr, 0, mSlots.Count * sizeof(uint64));
		mText.Reset();
		AddPredefined();
	}

	/// A seeded hash of the bytes, read as whole words (overlapping at the end, never past it).
	[Inline]
	uint32 Hash(char8* ptr, int length)
	{
		uint64 h = mSeed ^ ((uint64)length << 56);
		if (length >= 8)
		{
			int i = 0;
			while (i + 8 < length)
			{
				h = Mix(h ^ XmlChar.Load64(ptr + i));
				i += 8;
			}
			h = Mix(h ^ XmlChar.Load64(ptr + length - 8));
		}
		else if (length >= 4)
			h = Mix(h ^ (((uint64)XmlChar.Load32(ptr) << 24) | XmlChar.Load32(ptr + length - 4)));
		else if (length > 0)
			h = Mix(h ^ ((uint64)(uint8)ptr[0] | ((uint64)(uint8)ptr[length >> 1] << 8) | ((uint64)(uint8)ptr[length - 1] << 16)));
		// The high half of a multiply: every input bit reaches the slot bits
		h = (h ^ (h >> 32)) &* 0xD6E8FEB86659FD93UL;
		return (uint32)(h >> 32);
	}

	[Inline]
	static uint64 Mix(uint64 x)
	{
		uint64 m = x &* 0x9E3779B97F4A7C15UL;
		return m ^ (m >> 29);
	}

	/// Recently interned names, direct-mapped by first byte, last byte and length: documents repeat a
	/// few names, and a hit costs a compare instead of a hash and a probe.
	uint32[256] mCache;

	/// @brief Intern with the recent-name cache in front (the reader's element and attribute names).
	/// @param text The name (not empty).
	/// @return Its ID.
	[Inline]
	public XmlNameId InternCached(StringView text)
	{
		int length = text.Length;
		uint32 index = ((uint32)(uint8)text.Ptr[0] ^ ((uint32)(uint8)text.Ptr[length - 1] << 3) ^ ((uint32)length << 5)) & 0xFF;
		// Not cleared with the table: an ID from before is checked against the entries like any other
		uint32 id = mCache[index];
		if (id != 0 && id < (uint32)mEntries.Count)
		{
			ref Entry entry = ref mEntries[id];
			if (entry.mLength == length && XmlChar.EqualBytes(entry.mPtr, text.Ptr, length))
				return .(id);
		}
		let interned = Intern(text);
		mCache[index] = interned.mValue;
		return interned;
	}

	/// @brief Find with the recent-name cache in front (the typed mapping's lookups of the names it maps).
	/// @param text The string.
	/// @return Its ID, or XmlNameId.None.
	[Inline]
	public XmlNameId FindCached(StringView text)
	{
		int length = text.Length;
		if (length == 0)
			return .None;
		uint32 index = ((uint32)(uint8)text.Ptr[0] ^ ((uint32)(uint8)text.Ptr[length - 1] << 3) ^ ((uint32)length << 5)) & 0xFF;
		uint32 id = mCache[index];
		if (id != 0 && id < (uint32)mEntries.Count)
		{
			ref Entry entry = ref mEntries[id];
			if (entry.mLength == length && XmlChar.EqualBytes(entry.mPtr, text.Ptr, length))
				return .(id);
		}
		let found = Find(text);
		if (found.IsValid)
			mCache[index] = found.mValue;
		return found;
	}

	/// @brief The ID of `text`, interning a copy of it if it is new.
	/// @param text The string.
	/// @return Its ID.
	[Inline]
	public XmlNameId Intern(StringView text)
	{
		uint32 hash = Hash(text.Ptr, text.Length);
		uint32 mask = (uint32)mSlots.Count - 1;
		uint32 slot = hash & mask;
		while (true)
		{
			uint64 entrySlot = mSlots[slot];
			if (entrySlot == 0)
				break;
			if ((uint32)(entrySlot >> 32) == hash)
			{
				uint32 id = (uint32)entrySlot;
				ref Entry entry = ref mEntries[id];
				if (entry.mLength == text.Length && XmlChar.EqualBytes(entry.mPtr, text.Ptr, text.Length))
					return .(id);
			}
			slot = (slot + 1) & mask;
		}
		return Add(text, hash, slot);
	}

	/// Adds a name not in the table at `slot`.
	XmlNameId Add(StringView text, uint32 hash, uint32 slot)
	{
		Entry entry = default;
		entry.mPtr = mText.Alloc(Math.Max(text.Length, 1));
		Internal.MemCpy(entry.mPtr, text.Ptr, text.Length);
		entry.mLength = (int32)text.Length;
		entry.mHash = hash;
		entry.mColon = (int32)text.IndexOf(':');
		uint32 newId = (uint32)mEntries.Count;
		mEntries.Add(entry);
		mSlots[slot] = ((uint64)hash << 32) | newId;
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
			uint64 entrySlot = mSlots[slot];
			if (entrySlot == 0)
				return .None;
			if ((uint32)(entrySlot >> 32) == hash)
			{
				uint32 id = (uint32)entrySlot;
				ref Entry entry = ref mEntries[id];
				if (entry.mLength == text.Length && XmlChar.EqualBytes(entry.mPtr, text.Ptr, text.Length))
					return .(id);
			}
			slot = (slot + 1) & mask;
		}
	}

	void Rehash()
	{
		uint64[] old = mSlots;
		mSlots = new uint64[old.Count * 2];
		uint32 mask = (uint32)mSlots.Count - 1;
		for (int id = 1; id < mEntries.Count; id++)
		{
			uint32 hash = mEntries[id].mHash;
			uint32 slot = hash & mask;
			while (mSlots[slot] != 0)
				slot = (slot + 1) & mask;
			mSlots[slot] = ((uint64)hash << 32) | (uint32)id;
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
