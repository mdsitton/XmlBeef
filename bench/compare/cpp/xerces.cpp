// Xerces-C++ benchmark: xerces <file-or-dir> <min-samples>
// XercesDOMParser into its DOM: namespace-aware, non-validating (Val_Never), the external DTD not
// loaded, entity references expanded (no entity reference nodes), whitespace kept. Parses from a
// MemBufInputSource over the bytes (encoding detected, UTF-16 by its BOM); resetDocumentPool frees each
// document within the timed run. The walk for the check line is not timed. Prints the check line
// (see run.sh) first.
#include <cstdio>
#include <cstdlib>
#include <xercesc/dom/DOM.hpp>
#include <xercesc/framework/MemBufInputSource.hpp>
#include <xercesc/parsers/XercesDOMParser.hpp>
#include <xercesc/sax/HandlerBase.hpp>
#include <xercesc/util/PlatformUtils.hpp>
#include <xercesc/util/XMLString.hpp>
#include "../c/bench.h"

using namespace xercesc;

struct Ctx
{
	inputs_t in;
	XercesDOMParser* parser;
};

static bool xmlns(const XMLCh* name)
{
	static const XMLCh prefix[] = {'x', 'm', 'l', 'n', 's', 0};
	return XMLString::startsWith(name, prefix) && (name[5] == 0 || name[5] == ':');
}

static long chars(const XMLCh* s)
{
	return utf16_chars(reinterpret_cast<const uint16_t*>(s), XMLString::stringLen(s));
}

static void walk(DOMNode* node, check_t& c)
{
	for (DOMNode* child = node->getFirstChild(); child; child = child->getNextSibling())
	{
		switch (child->getNodeType())
		{
		case DOMNode::ELEMENT_NODE:
		{
			c.elements++;
			DOMNamedNodeMap* attrs = child->getAttributes();
			for (XMLSize_t i = 0; i < attrs->getLength(); i++)
			{
				DOMNode* a = attrs->item(i);
				if (xmlns(a->getNodeName()))
					continue;
				c.attributes++;
				c.attr_chars += chars(a->getNodeValue());
			}
			walk(child, c);
			break;
		}
		case DOMNode::TEXT_NODE:
		case DOMNode::CDATA_SECTION_NODE:
			c.text_chars += chars(child->getNodeValue());
			break;
		default:
			break;
		}
	}
}

static check_t parse_all(Ctx& x, bool check)
{
	check_t total = {0, 0, 0, 0};
	for (int i = 0; i < x.in.count; i++)
	{
		MemBufInputSource source(reinterpret_cast<const XMLByte*>(x.in.docs[i].data), x.in.docs[i].size, "input", false);
		x.parser->parse(source);
		if (x.parser->getErrorCount() > 0)
		{
			std::fprintf(stderr, "parse error\n");
			std::exit(1);
		}
		if (check)
			walk(x.parser->getDocument(), total);
		x.parser->resetDocumentPool();
	}
	return total;
}

// Reports the first error and stops counting on (the parser records the error count)
class Errors : public HandlerBase
{
public:
	void fatalError(const SAXParseException& e) override
	{
		char* message = XMLString::transcode(e.getMessage());
		std::fprintf(stderr, "parse error at line %lu: %s\n", (unsigned long)e.getLineNumber(), message);
		XMLString::release(&message);
		std::exit(1);
	}
};

int main(int argc, char** argv)
{
	if (argc < 3)
	{
		std::fprintf(stderr, "usage: xerces <file-or-dir> <min-samples>\n");
		return 2;
	}
	XMLPlatformUtils::Initialize();
	{
		static Ctx x;
		read_inputs(&x.in, argv[1]);
		XercesDOMParser parser;
		Errors errors;
		parser.setErrorHandler(&errors);
		parser.setValidationScheme(XercesDOMParser::Val_Never);
		parser.setDoNamespaces(true);
		parser.setDoSchema(false);
		parser.setLoadExternalDTD(false);
		parser.setCreateEntityReferenceNodes(false);
		parser.setIncludeIgnorableWhitespace(true);
		x.parser = &parser;
		print_check(parse_all(x, true));
		std::fflush(stdout);
		print_result(measure([](void* p) { parse_all(*static_cast<Ctx*>(p), false); }, &x, std::atoi(argv[2])), x.in.total);
	}
	XMLPlatformUtils::Terminate();
	return 0;
}
