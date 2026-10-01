// libexpat benchmark: expat <file-or-dir> <min-samples>
// Expat is a streaming (SAX) parser with no document: one run feeds each whole buffer to a namespace-
// aware parser (XML_ParserCreateNS, so namespace declarations are consumed, not reported as
// attributes) whose callbacks count elements and attributes and add up attribute value and character
// data lengths (CDATA sections arrive as character data too). Internal entities are expanded; the
// external DTD is not read. Expat detects UTF-16 by its BOM. Prints the check line (see run.sh) first.
#include <expat.h>
#include "bench.h"

typedef struct
{
	inputs_t in;
	check_t sum;
	bool check;
} ctx_t;

static ctx_t *X;

static long len(const XML_Char *s, int n)
{
	return X->check ? utf8_chars(s, (size_t)n) : n;
}

static void XMLCALL on_start(void *data, const XML_Char *name, const XML_Char **atts)
{
	check_t *c = (check_t *)data;
	(void)name;
	c->elements++;
	for (int i = 0; atts[i]; i += 2)
	{
		c->attributes++;
		c->attr_chars += len(atts[i + 1], (int)strlen(atts[i + 1]));
	}
}

static void XMLCALL on_end(void *data, const XML_Char *name)
{
	(void)data;
	(void)name;
}

static void XMLCALL on_text(void *data, const XML_Char *s, int n)
{
	((check_t *)data)->text_chars += len(s, n);
}

static check_t parse_one(doc_t *d)
{
	check_t c = {0};
	XML_Parser p = XML_ParserCreateNS(NULL, '\t');
	XML_SetUserData(p, &c);
	XML_SetElementHandler(p, on_start, on_end);
	XML_SetCharacterDataHandler(p, on_text);
	if (XML_Parse(p, d->data, (int)d->size, 1) != XML_STATUS_OK)
	{
		fprintf(stderr, "parse error: %s at line %lu\n", XML_ErrorString(XML_GetErrorCode(p)),
			(unsigned long)XML_GetCurrentLineNumber(p));
		exit(1);
	}
	XML_ParserFree(p);
	return c;
}

static check_t parse_all(ctx_t *x, bool check)
{
	check_t total = {0};
	x->check = check;
	for (int i = 0; i < x->in.count; i++)
	{
		check_t c = parse_one(&x->in.docs[i]);
		total.elements += c.elements;
		total.attributes += c.attributes;
		total.attr_chars += c.attr_chars;
		total.text_chars += c.text_chars;
	}
	return total;
}

static void op(void *p)
{
	ctx_t *x = (ctx_t *)p;
	x->sum = parse_all(x, false);
}

int main(int argc, char **argv)
{
	if (argc < 3)
	{
		fprintf(stderr, "usage: expat <file-or-dir> <min-samples>\n");
		return 2;
	}
	static ctx_t x;
	X = &x;
	read_inputs(&x.in, argv[1]);
	print_check(parse_all(&x, true));
	fflush(stdout);
	print_result(measure(op, &x, atoi(argv[2])), x.in.total);
	return 0;
}
