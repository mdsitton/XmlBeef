using System;
using FormatCore;
using internal FormatCore;

namespace XmlBeef;

/// Plain bytes in chunks that never move, for text with one lifetime (a document's, a name table's, a
/// DTD's): FormatCore's TextArena (which started as this one). `Reset` keeps every chunk for reuse, so
/// reading document after document allocates nothing once the arena has grown to the largest.
typealias XmlTextArena = TextArena;
