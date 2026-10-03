using System;
using FormatCore;
using internal FormatCore;

namespace XmlBeef;

/// A growable array of values for the document's tables and the reader's stacks: FormatCore's GrowList
/// (which started as this one): `Add`, `PopBack`, `Back` and the indexer are inlined, which corlib's
/// List.Add and Count setter are not (each showed up in profiles).
typealias XmlStack<T> = GrowList<T>;
