// Package canon implements B1-CANON-1 (SPEC/20-b1-canon-1.md).
//
// A hand-written parser is used rather than encoding/json for a specific reason: the standard
// decoder silently replaces unpaired surrogates with U+FFFD and keeps the last of a set of
// duplicate member names. Both are exactly the silent repairs the profile forbids — a repaired
// document produces a digest no other implementation reproduces, converting a loud failure into a
// quiet divergence.
package canon

import (
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"
)

const (
	MaxDepth = 64
	MaxSafe  = 9007199254740991 // 2^53 - 1
)

// Error tokens, per SPEC/20 §6.
var (
	ErrParse      = errors.New("B1_ERR_PARSE")
	ErrNonInteger = errors.New("B1_ERR_NONINTEGER_NUMBER")
	ErrKeySyntax  = errors.New("B1_ERR_KEY_SYNTAX")
	ErrDuplicate  = errors.New("B1_ERR_DUPLICATE_KEY")
	ErrInvalidUTF = errors.New("B1_ERR_INVALID_UTF8")
	ErrDepth      = errors.New("B1_ERR_DEPTH")
)

// Token returns the stable B1_ERR_* string for an error produced by this package.
func Token(err error) string {
	for _, e := range []error{ErrNonInteger, ErrKeySyntax, ErrDuplicate, ErrInvalidUTF, ErrDepth, ErrParse} {
		if errors.Is(err, e) {
			return e.Error()
		}
	}
	return ErrParse.Error()
}

// Value is a B1-CANON-1 document. There is no float case: R1 forbids non-integer numbers.
type Value interface{ isValue() }

type (
	Null   struct{}
	Bool   bool
	Int    int64
	String string
	Array  []Value
	Object struct {
		keys   []string
		values map[string]Value
	}
)

func (Null) isValue()    {}
func (Bool) isValue()    {}
func (Int) isValue()     {}
func (String) isValue()  {}
func (Array) isValue()   {}
func (*Object) isValue() {}

func NewObject() *Object {
	return &Object{values: map[string]Value{}}
}

func (o *Object) Set(key string, v Value) *Object {
	if _, seen := o.values[key]; !seen {
		o.keys = append(o.keys, key)
	}
	o.values[key] = v
	return o
}

func (o *Object) Get(key string) (Value, bool) {
	v, ok := o.values[key]
	return v, ok
}

// SortedKeys returns member names in canonical order. R2 restricts names to ASCII, so byte order
// is the required order and a plain sort is unambiguous across all fourteen languages.
func (o *Object) SortedKeys() []string {
	out := append([]string(nil), o.keys...)
	sort.Strings(out)
	return out
}

func KeySyntaxOK(k string) bool {
	if len(k) < 1 || len(k) > 64 {
		return false
	}
	for i := 0; i < len(k); i++ {
		c := k[i]
		ok := (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') ||
			c == '_' || c == '$' || c == '.' || c == '-'
		if !ok {
			return false
		}
	}
	return true
}

// --- parser ------------------------------------------------------------------

type parser struct {
	s string
	i int
}

func (p *parser) ws() {
	for p.i < len(p.s) {
		switch p.s[p.i] {
		case ' ', '\t', '\n', '\r':
			p.i++
		default:
			return
		}
	}
}

func (p *parser) lit(word string) error {
	if strings.HasPrefix(p.s[p.i:], word) {
		p.i += len(word)
		return nil
	}
	return ErrParse
}

func (p *parser) value(depth int) (Value, error) {
	if depth > MaxDepth {
		return nil, ErrDepth
	}
	if p.i >= len(p.s) {
		return nil, ErrParse
	}
	switch c := p.s[p.i]; {
	case c == '{':
		return p.object(depth)
	case c == '[':
		return p.array(depth)
	case c == '"':
		s, err := p.str()
		return String(s), err
	case c == 't':
		return Bool(true), p.lit("true")
	case c == 'f':
		return Bool(false), p.lit("false")
	case c == 'n':
		return Null{}, p.lit("null")
	case c == '-' || (c >= '0' && c <= '9'):
		n, err := p.number()
		return Int(n), err
	default:
		return nil, ErrParse
	}
}

func (p *parser) object(depth int) (Value, error) {
	p.i++
	obj := NewObject()
	p.ws()
	if p.i < len(p.s) && p.s[p.i] == '}' {
		p.i++
		return obj, nil
	}
	for {
		p.ws()
		if p.i >= len(p.s) || p.s[p.i] != '"' {
			return nil, ErrParse
		}
		key, err := p.str()
		if err != nil {
			return nil, err
		}
		if !KeySyntaxOK(key) {
			return nil, ErrKeySyntax
		}
		if _, seen := obj.values[key]; seen {
			return nil, ErrDuplicate
		}
		p.ws()
		if p.i >= len(p.s) || p.s[p.i] != ':' {
			return nil, ErrParse
		}
		p.i++
		p.ws()
		v, err := p.value(depth + 1)
		if err != nil {
			return nil, err
		}
		obj.Set(key, v)
		p.ws()
		if p.i >= len(p.s) {
			return nil, ErrParse
		}
		switch p.s[p.i] {
		case ',':
			p.i++
		case '}':
			p.i++
			return obj, nil
		default:
			return nil, ErrParse
		}
	}
}

func (p *parser) array(depth int) (Value, error) {
	p.i++
	out := Array{}
	p.ws()
	if p.i < len(p.s) && p.s[p.i] == ']' {
		p.i++
		return out, nil
	}
	for {
		p.ws()
		v, err := p.value(depth + 1)
		if err != nil {
			return nil, err
		}
		out = append(out, v)
		p.ws()
		if p.i >= len(p.s) {
			return nil, ErrParse
		}
		switch p.s[p.i] {
		case ',':
			p.i++
		case ']':
			p.i++
			return out, nil
		default:
			return nil, ErrParse
		}
	}
}

func (p *parser) number() (int64, error) {
	start := p.i
	if p.s[p.i] == '-' {
		p.i++
	}
	digitsStart := p.i
	for p.i < len(p.s) && p.s[p.i] >= '0' && p.s[p.i] <= '9' {
		p.i++
	}
	if p.i == digitsStart {
		return 0, ErrParse
	}
	if p.i-digitsStart > 1 && p.s[digitsStart] == '0' {
		return 0, ErrParse // leading zero
	}
	if p.i < len(p.s) {
		if c := p.s[p.i]; c == '.' || c == 'e' || c == 'E' {
			return 0, ErrNonInteger
		}
	}
	text := p.s[start:p.i]
	if text == "-0" {
		return 0, ErrNonInteger
	}
	v, err := strconv.ParseInt(text, 10, 64)
	if err != nil || v > MaxSafe || v < -MaxSafe {
		return 0, ErrNonInteger
	}
	return v, nil
}

func (p *parser) hex4() (rune, error) {
	if p.i+4 > len(p.s) {
		return 0, ErrParse
	}
	var v rune
	for k := 0; k < 4; k++ {
		c := p.s[p.i+k]
		v <<= 4
		switch {
		case c >= '0' && c <= '9':
			v |= rune(c - '0')
		case c >= 'a' && c <= 'f':
			v |= rune(c-'a') + 10
		case c >= 'A' && c <= 'F':
			v |= rune(c-'A') + 10
		default:
			return 0, ErrParse
		}
	}
	p.i += 4
	return v, nil
}

// unicodeEscape decodes one \uXXXX, joining a surrogate pair into a single scalar. Either half
// appearing alone is rejected — see SPEC/20 R3.
func (p *parser) unicodeEscape() (rune, error) {
	cp, err := p.hex4()
	if err != nil {
		return 0, err
	}
	if cp >= 0xD800 && cp <= 0xDBFF {
		if p.i+2 > len(p.s) || p.s[p.i] != '\\' || p.s[p.i+1] != 'u' {
			return 0, ErrInvalidUTF
		}
		p.i += 2
		low, err := p.hex4()
		if err != nil {
			return 0, err
		}
		if low < 0xDC00 || low > 0xDFFF {
			return 0, ErrInvalidUTF
		}
		return 0x10000 + (cp-0xD800)<<10 + (low - 0xDC00), nil
	}
	if cp >= 0xDC00 && cp <= 0xDFFF {
		return 0, ErrInvalidUTF
	}
	return cp, nil
}

func (p *parser) str() (string, error) {
	p.i++ // opening quote
	var b strings.Builder
	for {
		if p.i >= len(p.s) {
			return "", ErrParse
		}
		c := p.s[p.i]
		if c == '"' {
			p.i++
			return b.String(), nil
		}
		if c == '\\' {
			p.i++
			if p.i >= len(p.s) {
				return "", ErrParse
			}
			e := p.s[p.i]
			p.i++
			switch e {
			case '"':
				b.WriteByte('"')
			case '\\':
				b.WriteByte('\\')
			case '/':
				b.WriteByte('/')
			case 'b':
				b.WriteByte('\b')
			case 'f':
				b.WriteByte('\f')
			case 'n':
				b.WriteByte('\n')
			case 'r':
				b.WriteByte('\r')
			case 't':
				b.WriteByte('\t')
			case 'u':
				r, err := p.unicodeEscape()
				if err != nil {
					return "", err
				}
				b.WriteRune(r)
			default:
				return "", ErrParse
			}
			continue
		}
		if c < 0x20 {
			return "", ErrParse // raw control character
		}
		r, size := utf8.DecodeRuneInString(p.s[p.i:])
		if r == utf8.RuneError && size <= 1 {
			return "", ErrInvalidUTF
		}
		b.WriteString(p.s[p.i : p.i+size])
		p.i += size
	}
}

// Parse strictly parses a B1-CANON-1 document.
func Parse(text string) (Value, error) {
	if !utf8.ValidString(text) {
		return nil, ErrInvalidUTF
	}
	p := &parser{s: text}
	p.ws()
	v, err := p.value(0)
	if err != nil {
		return nil, err
	}
	p.ws()
	if p.i != len(p.s) {
		return nil, ErrParse // trailing input
	}
	return v, nil
}

// --- serialization ------------------------------------------------------------

func escapeInto(b *strings.Builder, s string) {
	b.WriteByte('"')
	for _, r := range s {
		switch r {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\b':
			b.WriteString(`\b`)
		case '\t':
			b.WriteString(`\t`)
		case '\n':
			b.WriteString(`\n`)
		case '\f':
			b.WriteString(`\f`)
		case '\r':
			b.WriteString(`\r`)
		default:
			if r < 0x20 {
				fmt.Fprintf(b, `\u%04x`, r) // lowercase, per R3
			} else {
				b.WriteRune(r)
			}
		}
	}
	b.WriteByte('"')
}

func canonInto(b *strings.Builder, v Value, depth int) error {
	if depth > MaxDepth {
		return ErrDepth
	}
	switch t := v.(type) {
	case Null:
		b.WriteString("null")
	case Bool:
		if t {
			b.WriteString("true")
		} else {
			b.WriteString("false")
		}
	case Int:
		if int64(t) > MaxSafe || int64(t) < -MaxSafe {
			return ErrNonInteger
		}
		b.WriteString(strconv.FormatInt(int64(t), 10))
	case String:
		escapeInto(b, string(t))
	case Array:
		b.WriteByte('[')
		for i, item := range t {
			if i > 0 {
				b.WriteByte(',')
			}
			if err := canonInto(b, item, depth+1); err != nil {
				return err
			}
		}
		b.WriteByte(']')
	case *Object:
		b.WriteByte('{')
		for i, k := range t.SortedKeys() {
			if !KeySyntaxOK(k) {
				return ErrKeySyntax
			}
			if i > 0 {
				b.WriteByte(',')
			}
			escapeInto(b, k)
			b.WriteByte(':')
			if err := canonInto(b, t.values[k], depth+1); err != nil {
				return err
			}
		}
		b.WriteByte('}')
	default:
		return ErrParse
	}
	return nil
}

func Canonicalize(v Value) (string, error) {
	var b strings.Builder
	if err := canonInto(&b, v, 0); err != nil {
		return "", err
	}
	return b.String(), nil
}

func DigestValue(v Value) (string, error) {
	c, err := Canonicalize(v)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256([]byte(c))
	return hex.EncodeToString(sum[:]), nil
}

func DigestText(text string) (string, error) {
	v, err := Parse(text)
	if err != nil {
		return "", err
	}
	return DigestValue(v)
}

// B1C1 returns the algorithm-labelled identifier form. The prefix is not hashed; it labels the
// algorithm so a future B1-CANON-2 cannot be silently confused with this one.
func B1C1(digestHex string) string { return "b1c1:" + digestHex }

const ZeroLink = "b1c1:0000000000000000000000000000000000000000000000000000000000000000"
