using System;
using XmlBeef;

namespace Other;

/// A second project using XmlBeef, unrelated to Fixtures: with two dependents, XmlBeef's old
/// ApplyToType-time lookups no longer saw the converters Fixtures registers (OkRegisteredConverter).
[XmlObject]
class OtherThing
{
	public int32 count;
}
