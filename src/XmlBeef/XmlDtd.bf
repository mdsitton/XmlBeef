using System;
using System.Collections;
using internal XmlBeef;

namespace XmlBeef;

/// @brief The `standalone` pseudo-attribute of an XML declaration.
public enum XmlStandalone : uint8
{
	/// @brief Not given (no declaration, or no `standalone=`).
	Unspecified,
	/// @brief `standalone="yes"`.
	Yes,
	/// @brief `standalone="no"`.
	No
}

/// @brief A notation declared in the internal subset (`<!NOTATION name PUBLIC "…" "…">`).
public struct XmlNotation
{
	/// @brief The notation's name.
	public StringView mName;
	/// @brief The public identifier, normalized (whitespace runs collapsed, trimmed); empty if none.
	public StringView mPublicId;
	/// @brief The system identifier as written; empty if none.
	public StringView mSystemId;
	/// @brief Whether a public identifier was given.
	public bool mHasPublicId;
	/// @brief Whether a system identifier was given.
	public bool mHasSystemId;
}

/// The declared type of an attribute (§3.3.1). Every type but CDATA trims and collapses spaces in the
/// value (§3.3.3).
internal enum XmlAttributeType : uint8
{
	CData,
	Id,
	IdRef,
	IdRefs,
	Entity,
	Entities,
	NmToken,
	NmTokens,
	Notation,
	Enumeration
}

/// How an attribute's default is declared (§3.3.2).
internal enum XmlDefaultKind : uint8
{
	Required,
	Implied,
	Fixed,
	Value
}

/// An attribute declared by `<!ATTLIST>` (the first declaration of a name binds).
internal struct XmlAttributeDecl
{
	public XmlNameId mName;
	public XmlAttributeType mType;
	public XmlDefaultKind mDefault;
	/// The default (Fixed, Value), normalized for the type; owned by the DTD.
	public StringView mDefaultValue;
	/// Whether the default came from expanding entity references (counted against the expansion
	/// limits each time it is applied).
	public bool mExpanded;
}

/// A general or parameter entity declared in the internal subset.
internal class XmlEntity
{
	public String mName ~ delete _;
	/// The replacement text of an internal entity (character references expanded, general entity
	/// references left as written; a parameter entity's has a space added at each end, §4.4.8, since
	/// the internal subset includes it only between declarations); null for an external one.
	public String mValue ~ delete _;
	public String mSystemId ~ delete _;
	public String mPublicId ~ delete _;
	/// The notation of an unparsed entity (`NDATA`); null otherwise.
	public String mNotation ~ delete _;
	public bool mParameter;
	/// Declared inside a parameter entity's replacement text.
	public bool mInParameterEntity;
	/// Being expanded (No Recursion).
	public bool mExpanding;

	public this()
	{
		mName = new .();
	}

	public bool IsExternal => mValue == null;
	public bool IsUnparsed => mNotation != null;
}

/// What the reader keeps of the DOCTYPE: entities, attribute declarations and notations from the
/// internal subset, and the facts that decide the Entity Declared rule (§4.1).
internal class XmlDtd
{
	public Dictionary<StringView, XmlEntity> mGeneral ~ DeleteDictionaryAndValues!(_);
	public Dictionary<StringView, XmlEntity> mParameter ~ DeleteDictionaryAndValues!(_);
	/// Attribute declarations by element name.
	public Dictionary<XmlNameId, List<XmlAttributeDecl>> mAttributes ~ DeleteDictionaryAndValues!(_);
	public List<XmlNotation> mNotations ~ delete _;
	XmlTextArena mText ~ delete _;

	/// A DOCTYPE was read.
	public bool mPresent;
	/// It names an external subset (never read).
	public bool mHasExternalSubset;
	/// The internal subset has a parameter-entity reference.
	public bool mHasParameterReferences;
	/// A parameter entity was not read (external or undeclared): ENTITY and ATTLIST declarations after
	/// it are not processed unless the document is standalone (§5.1).
	public bool mSkippedParameterEntity;
	/// The first reference to an undeclared general entity in an ATTLIST default (-1: none), fatal
	/// once the DTD turns out to be one where Entity Declared is a well-formedness constraint.
	public int mUndeclaredInDefault = -1;
	public int mUndeclaredInDefaultLength;

	public this()
	{
		mGeneral = new .();
		mParameter = new .();
		mAttributes = new .();
		mNotations = new .();
		mText = new XmlTextArena(1024);
	}

	public void Clear()
	{
		// Everything here comes from a DOCTYPE
		if (!mPresent)
			return;
		for (let entity in mGeneral.Values)
			delete entity;
		mGeneral.Clear();
		for (let entity in mParameter.Values)
			delete entity;
		mParameter.Clear();
		for (let list in mAttributes.Values)
			delete list;
		mAttributes.Clear();
		mNotations.Clear();
		mText.Reset();
		mPresent = false;
		mHasExternalSubset = false;
		mHasParameterReferences = false;
		mSkippedParameterEntity = false;
		mUndeclaredInDefault = -1;
		mUndeclaredInDefaultLength = 0;
	}

	/// A copy of `text` owned by the DTD.
	public StringView Own(StringView text)
	{
		return mText.Copy(text);
	}

	/// The attribute declarations of an element type, or null.
	[Inline]
	public List<XmlAttributeDecl> GetAttributes(XmlNameId element)
	{
		if (mAttributes.Count == 0)
			return null;
		if (mAttributes.TryGetValue(element, let list))
			return list;
		return null;
	}

	/// The notation named `name`, or null.
	public XmlNotation* FindNotation(StringView name)
	{
		for (var notation in ref mNotations)
		{
			if (notation.mName == name)
				return &notation;
		}
		return null;
	}
}
