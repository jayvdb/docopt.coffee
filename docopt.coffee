print = () -> console.log.apply(@, [].slice.call(arguments))

class UsageMessageError extends Error
    constructor: (message) ->
        print message

class DocoptExit extends Error
    constructor: (message) ->
        print message
        process.exit(1)
    @usage: ''


class Pattern
  constructor: (@children) ->
  valueOf: @toString
  toString: () ->
      formals = (child.toString() for child in @children).join(', ')
      "#{@constructor.name}(#{formals})"
  flat: () ->
      if @hasOwnProperty('children')
          return [@]
      return (grandchild for grandchild in child.flat() for child in children)

class Option extends Pattern
    constructor: (@short=null, @long=null, @argcount=0, @value=false) ->
    toString: -> "Option(#{@short}, #{@long}, #{@argcount}, #{@value})"
    name: -> @long or @short
    @parse: (description) ->
        # strip whitespaces
        description = description.replace(/^\s*|\s*$/g, '')
        # split on first occurence of 2 consecutive spaces ('  ')
        [_, options,
         description] = description.match(/(.*?)  (.*)/) ? [null, description, '']
        # replace ',' or '=' with ' '
        options = options.replace(/,|=/g, ' ' )
        # set some defaults
        [short, long, argcount, value] = [null, null, 0, false]
        for s in options.split(/\s+/)  # split on spaces
            if s[0..1] is '--'
                long = s
            else if s[0] is '-'
                short = s
            else
                argcount = 1
        if argcount is 1
            matched = description.match(/\[default: (.*)\]/)
            value = if matched then matched[1] else false
        new Option(short, long, argcount, value)


class Required extends Pattern
    constructor: (children) ->
        super children
    

# same as TokenStream in python
class TokenStream extends Array
    constructor: (source, @error) ->
        stream =
           if source.constructor is String
               source.split(/\s+/)
           else
               source
        @push.apply @, stream
    shift: -> [].shift.apply(@) or null
    current: -> @[0] or null
    toString: -> ([].slice.apply @).toString()
    join: (glue) -> ([].join.apply @, glue)
    error: (message) ->
        throw new @error(message)


parse_shorts = (tokens, options) ->
    raw = tokens.shift()[1..]
    parsed = []
    while raw != ''
        opt = (o for o in options when o.short and o.short[1] == raw[0])
        if opt.length > 1
            tokens.error "-#{raw[0]} is specified ambiguously #{opt.length} times"
        if opt.length < 1
            tokens.error "-#{raw[0]} is not recognized"
        opt = opt[0] #####copy?  opt = copy(opt[0])
        raw = raw[1..]
        if opt.argcount == 0
            value = true
        else
            if raw == ''
                if tokens.current() is null
                    tokens.error "-#{opt.short[0]} requires argument"
                raw = tokens.shift()
            [value, raw] = [raw, '']
        opt.value = value
        parsed.push(opt)
    return parsed


parse_long = (tokens, options) ->
    [_, raw, value] = tokens.current().match(/(.*?)=(.*)/) ? [null,
                                                      tokens.current(), '']
    tokens.shift()
    value = if value == '' then null else value
    opt = (o for o in options when o.long and o.long[0...raw.length] == raw)
    if opt.length < 1
        tokens.error "-#{raw} is not recognized"
    if opt.length > 1
        tokens.error "-#{raw} is not a unique prefix"  # TODO report ambiguity
    opt = opt[0]  #copy? opt = copy(opt[0])
    if opt.argcount == 1
        if value is null
            if tokens.current() is null
                tokens.error "#{opt.name} requires argument"
            value = tokens.shift()
    else if value is not null
        tokens.error "#{opt.name} must not have an argument"
    opt.value = value or true
    return [opt]


parse_pattern = (source, options) ->
    tokens = new TokenStream(source.replace(/([\[\]\(\)\|]|\.\.\.)/, ' $1 '),
                         UsageMessageError)
    result = parse_expr(tokens, options)
    if tokens.current() is not null
        raise tokens.error('unexpected ending: ' + tokens.join(' '))
    return new Required(result)


parse_expr = (tokens, options) ->
    # expr ::= seq , ( '|' seq )* ;
    seq = parse_seq(tokens, options)

    if tokens.current() != '|'
        return seq

    result = if seq.length > 1 then [new Required(seq)] else seq
    while tokens.current() == '|'
        tokens.next()
        seq = parse_seq(tokens, options)
        result.push(if seq.length > 1 then [new Required(seq)] else seq)

    return if result.length > 1 then [new Either(result)] else result


parse_seq = (tokens, options) ->
    # seq ::= ( atom [ '...' ] )* ;

    result = []
    while tokens.current() not in [null, ']', ')', '|']
        atom = parse_atom(tokens, options)
        if tokens.current() == '...'
            atom = [new OneOrMore(atom)]
            tokens.next()
        result.push(atom)
    return result


parse_atom = (tokens, options) ->
    # atom ::= '(' expr ')' | '[' expr ']' | '[' 'options' ']' | '--'
    #        | long | shorts | argument | command ;

    token = tokens.current()
    result = []
    if token == '('
        tokens.next()
        
        result = [new Required(parse_expr(tokens, options))]
        if tokens.next() != ')'
            raise tokens.error("Unmatched '('")
        return result
    else if token == '['
        tokens.next()
        if tokens.current() == 'options'
            result = [new Optional(new AnyOptions())]
            tokens.next()
        else
            result = [new Optional(parse_expr(tokens, options))]
        if tokens.next() != ']'
            raise tokens.error("Unmatched '['")
        return result
    else if token == '--'
        tokens.next()
        return []  # allow "usage: prog [-o] [--] <arg>"
    else if token[0..2] is '--'
        return parse_long(tokens, options)
    else if token[0] is '-'
        return parse_shorts(tokens, options)
    else if (token[0] is '<' and token[-1] is '>') or /^[^a-z]*$/.test(token)
        return [new Argument(tokens.next())]
    else
        return [new Command(tokens.next())]


parse_args = (source, options) ->
    tokens = new TokenStream(source)
    #options = options.slice(0) # shallow copy, not sure if necessary
    [opts, args] = [[], []]
    while not (tokens.current() is null)
        if tokens.current() == '--'
            tokens.shift()
            args = args.concat(tokens)
            break
        else if tokens.current()[0...2] == '--'
            opts = opts.concat(parse_long(tokens, options))
        else if tokens.current()[0] == '-' and tokens.current() != '-'
            opts = opts.concat(parse_shorts(tokens, options))
        else
            args.push(tokens.shift())
    return [opts, args]

parse_doc_options = (doc) ->
    (Option.parse('-' + s) for s in doc.split(/^ *-|\n *-/)[1..])

printable_usage = (doc, name) ->
    [usage, patterns] = doc.split(/(?:^|\n)([\s^\n]*usage:\s*)/i)[1..2]
    usage = usage.replace(/^\s+/, '')
    if not /\s$/.test(usage) then usage += ' '
    indent = '\n' + /(^)?[^\n]*$/.exec(usage)[0].replace(/./g, (c) ->
       return (if c is '\t' then '\t' else ' '))
    oldname = /^[^\s]+/.exec(patterns)[0]
    if name is null then name = oldname
    uses = patterns.split(/\n\s*\n/)[0]
    uses = uses.split(new RegExp('(?:^|\\n)\\s*' + oldname))
    uses = (name + u.replace /\s+$/, '' for u in uses[1..])
    return usage + uses.join(indent)

formal_usage = (printable_usage) ->
    pu = printable_usage.split()[1..]  # split and drop "usage:"
    ((if s == pu[0] then '|' else s) for s in pu[1..]).join(' ')

extras = (help, version, options, doc) ->
    opts = {}
    for opt in options
        if opt.value
            opts[opt.name()] = true
    if help and (opts['--help'] or opts['-h'])
        print(doc.strip())
        exit()
    if version and opts['--version']
        print(version)
        exit()

class Dict extends Object
    constructor: (pairs) ->
        (@[key] = value for [key, value] in pairs)
    toString: () ->
        '{' + (k + ': ' + @[k] for k of @).join(',\n  ') + '}'

docopt = (doc, argv=process.argv[1..], name=null, help=true, version=null) ->
    DocoptExit.usage = docopt.usage = usage = printable_usage(doc, name)
    pot_options = parse_doc_options(doc)
    [options, args] = parse_args(argv, pot_options)

    extras(help, version, options, doc)
    formal_pattern = parse_pattern(formal_usage(usage), pot_options)
#    pot_arguments = (a for a in formal_pattern.flat
#                     if a.constructor in [Argument, Command])
#    [matched, left, arguments] = formal_pattern.fix().match(argv)
#    if matched and left == []:  # better message if left?
#        args = Dict((a.name, a.value) for a in
#                 (pot_options + options + pot_arguments + arguments))
#        return args
#    throw new DocoptExit()

__all__ =
    docopt       : docopt
    Option       : Option
    TokenStream  : TokenStream
    parse_long   : parse_long
    parse_shorts : parse_shorts
    parse_args   : parse_args
    printable_usage: printable_usage

for fun of __all__
    exports[fun] = __all__[fun]
