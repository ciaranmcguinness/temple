/**
 * Temple (C) Dylan Knutson, 2014, distributed under the:
 * Boost Software License - Version 1.0 - August 17th, 2003
 *
 * Permission is hereby granted, free of charge, to any person or organization
 * obtaining a copy of the software and accompanying documentation covered by
 * this license (the "Software") to use, reproduce, display, distribute,
 * execute, and transmit the Software, and to prepare derivative works of the
 * Software, and to permit third-parties to whom the Software is furnished to
 * do so, all subject to the following:
 *
 * The copyright notices in the Software and this entire statement, including
 * the above license grant, this restriction and the following disclaimer,
 * must be included in all copies of the Software, in whole or in part, and
 * all derivative works of the Software, unless such copies or derivative
 * works are solely in the form of machine-executable object code generated by
 * a source language processor.
 */

module temple;

private import
	temple.util,
	temple.delims,
	temple.func_string_gen;
private import std.array : appender, Appender;
private import std.range : isOutputRange;
private import std.typecons : scoped;
private import std.stdio;
private import vibe.core.stream;

public {
    import temple.temple_context : TempleContext;
	import temple.output_stream  : TempleOutputStream, TempleInputStream;
	import temple.vibe;
}

/**
 * Temple
 * Main template for generating Temple functions
 */
CompiledTemple compile_temple(string __TempleString, __Filter = void, uint line = __LINE__, string file = __FILE__)()
{
    import std.conv : to;
    return compile_temple!(__TempleString, file~":"~line.to!string ~ ": InlineTemplate", __Filter);
}
deprecated("Please use compile_temple")
auto Temple(ARGS...)() {
    return .compile_temple!(ARGS)();
}

private
CompiledTemple compile_temple(
	string __TempleString,
	string __TempleName,
	__Filter = void)()
{
	// __TempleString: The template string to compile
	// __TempleName: The template's file name, or 'InlineTemplate'
	// __Filter: FP for the rendered template

	// Is a Filter present?
	enum __TempleHasFP = !is(__Filter == void);

	// Needs to be kept in sync with the param name of the Filter
	// passed to Temple
	enum __TempleFilterIdent = __TempleHasFP ? "__Filter" : "";

	// Generates the actual function string, with the function name being
	// `TempleFunc`.
	const __TempleFuncStr = __temple_gen_temple_func_string(
		__TempleString,
		__TempleName,
		__TempleFilterIdent);

	//pragma(msg, __TempleFuncStr);

	#line 1 "TempleFunc"
	mixin(__TempleFuncStr);
	#line 75 "src/temple/temple.d"

	static if(__TempleHasFP) {
		alias temple_func = TempleFunc!__Filter;
	}
	else {
		alias temple_func = TempleFunc;
	}

	return CompiledTemple(&temple_func, null);
}

/**
 * TempleFile
 * Compiles a file on the disk into a Temple render function
 * Takes an optional Filter
 */
CompiledTemple compile_temple_file(string template_file, Filter = void)()
{
	pragma(msg, "Compiling ", template_file, "...");
	return compile_temple!(import(template_file), template_file, Filter);
}

deprecated("Please use compile_temple_file")
auto TempleFile(ARGS...)() {
    return .compile_temple_file!(ARGS)();
}

/**
 * TempleFilter
 * Curries a Temple to always use a given template filter, for convienence
 */
template TempleFilter(Filter) {
    template compile_temple(ARGS...) {
        alias compile_temple = .compile_temple!(ARGS, Filter);
    }
    template compile_temple_file(ARGS...) {
        alias compile_temple_file = .compile_temple_file!(ARGS, Filter);
    }

    deprecated("Please compile_temple")      alias Temple     = compile_temple;
    deprecated("Please compile_temple_file") alias TempleFile = compile_temple_file;
}

/**
 * CompiledTemple
 */
package
struct CompiledTemple {

package:
    alias TempleFuncSig = void function(TempleContext);
    TempleFuncSig render_func = null;

    // renderer used to handle 'yield's
    const(CompiledTemple)* partial_rendr = null;

    this(TempleFuncSig rf, const(CompiledTemple*) cf)
    in { assert(rf); }
    body {
        this.render_func = rf;
        this.partial_rendr = cf;
    }

public:
    //deprecated static Temple opCall()

    // render template directly to a string
    string toString(TempleContext tc = null) const {
        auto a = appender!string();
        this.render(a, tc);
        return a.data;
    }

    // render using an arbitrary output range
    void render(T)(ref T os, TempleContext tc = null) const
    if(	isOutputRange!(T, string) &&
    	!is(T == TempleOutputStream))
    {
    	auto oc = TempleOutputStream(os);
    	return render(oc, tc);
    }

    // render using a sink function (DMD can't seem to cast a function to a delegate)
    void render(void delegate(string) sink, TempleContext tc = null) const {
    	auto oc = TempleOutputStream(sink);
    	this.render(oc, tc); }
    void render(void function(string) sink, TempleContext tc = null) const {
    	auto oc = TempleOutputStream(sink);
    	this.render(oc, tc); }
    void render(ref File f, TempleContext tc = null) const {
        auto oc = TempleOutputStream(f);
        this.render(oc, tc);
    }

    // normalized render function, using an TempleOutputStream
    package
    void render(ref TempleOutputStream os, TempleContext tc) const
    {
        // the context never escapes the scope of a template, so it's safe
        // to allocate a new context here
        // TODO: verify this is safe
        auto local_tc = scoped!TempleContext();

        // and always ensure that a template is passed, at the very least,
        // an empty context (needed for various template scope book keeping)
        if(tc is null) {
            tc = local_tc.Scoped_payload;
            //tc = new TempleContext();
        }

        // template renders into given output stream
        auto old = tc.sink;
        scope(exit) tc.sink = old;
        tc.sink = os;

        // use the layout if we've got one
        if(this.partial_rendr !is null) {
            auto old_partial = tc.partial;

                        tc.partial = this.partial_rendr;
            scope(exit) tc.partial = old_partial;

            this.render_func(tc);
        }
        // else, call this render function directly
        else {
            this.render_func(tc);
        }
    }

    // render using a vibe.d OutputStream
    version(Have_vibe_d) {
        private import vibe.core.stream : OutputStream;
        private import vibe.stream.wrapper : StreamOutputRange;

		void render(OutputStream os, TempleContext tc = null) {
            static assert(isOutputRange!(vibe.stream.wrapper.StreamOutputRange, string));

            auto sor = StreamOutputRange(os);
            this.render(sor, tc);
        }
    }

    CompiledTemple layout(const(CompiledTemple*) partial) const
    in {
        assert(this.partial_rendr is null, "attempting to set already-set partial of a layout");
    }
    body {
    	return CompiledTemple(this.render_func, partial);
    }

    invariant() {
        assert(render_func);
    }
}
