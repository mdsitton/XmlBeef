using System;

namespace XmlBeef;

static class XmlSmokeTests
{
	[Test]
	public static void Workspace_Builds()
	{
		Test.Assert(XmlVersion.V1_0 != XmlVersion.V1_1);
	}
}
