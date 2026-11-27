-- akl_math.lua
-- A small MathJax/LaTeX renderer for Ankilatro.
--
-- LÖVE has no web view, so we can't run MathJax itself. Instead this module
-- parses the subset of TeX that shows up on flashcards and lays it out with
-- Balatro's own UI nodes (rows, columns and boxes):
--   * symbols / greek / operators   -> Unicode glyphs
--   * ^ and _                       -> smaller text raised / lowered in a column
--   * \frac, \binom                 -> column with a box drawn as the fraction bar
--   * \sqrt, \overline, \hat, ...   -> glyph + box combinations
--   * \left( ... \right)            -> delimiters scaled to the content
--   * matrix / cases / aligned      -> grid of columns
--
-- Glyphs are drawn with GoNotoCurrent (bundled with Balatro), since the pixel
-- font m6x11 has no Greek or math symbols.
--
-- Public API:
--   M.parse(tex)                                  -> AST (pure Lua, no game needed)
--   M.segment(text)                               -> list of text / math segments
--   M.create_text_node(text, max_chars, scale)    -> UI node (G.UIT.C) with wrapped text + math

local M = {}
local markdown = require("lib.markdown")
-- Internal token for the active deletion. A literal "[...]" elsewhere stays ordinary text.
M.cloze_placeholder = '\31'
M.cloze_start = '\26'
M.cloze_end = '\25'
local cloze_marks = '[' .. M.cloze_start .. M.cloze_end .. ']'

local function cloze_depth(depth, mark)
    if mark == M.cloze_start then return depth + 1 end
    return math.max(0, depth - 1)
end

M.MATH_SCALE = 0.8     -- GoNoto has larger glyphs than m6x11; this matches cap heights
M.SCRIPT_RATIO = 0.7   -- size of super/subscripts relative to the base
M.FRAC_RATIO = 0.8     -- size of inline fraction parts relative to the base
M.MIN_RATIO = 0.45     -- never shrink below this fraction of the base math size

----------------------------------------------------------------------------
-- UTF-8 helpers (LuaJIT / Lua 5.1 has no utf8 library)
----------------------------------------------------------------------------
local function U(cp)
    if cp < 0x80 then return string.char(cp)
    elseif cp < 0x800 then
        return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
    elseif cp < 0x10000 then
        return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    else
        return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
            0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
    end
end

local function utf8_len_at(s, i)
    local c = s:byte(i)
    if not c or c < 0x80 then return 1
    elseif c < 0xE0 then return 2
    elseif c < 0xF0 then return 3
    else return 4 end
end

----------------------------------------------------------------------------
-- Symbol tables
----------------------------------------------------------------------------
-- name -> { text, class }   classes: ord, bin, rel, open, close, punct, op
local SYM = {}
local function add(class, t) for k, v in pairs(t) do SYM[k] = { v, class } end end

add('ord', {
    alpha = 'α', beta = 'β', gamma = 'γ', delta = 'δ', epsilon = 'ϵ', varepsilon = 'ε', zeta = 'ζ',
    eta = 'η', theta = 'θ', vartheta = 'ϑ', iota = 'ι', kappa = 'κ', varkappa = 'ϰ', lambda = 'λ',
    mu = 'μ', nu = 'ν', xi = 'ξ', omicron = 'ο', pi = 'π', varpi = 'ϖ', rho = 'ρ', varrho = 'ϱ',
    sigma = 'σ', varsigma = 'ς', tau = 'τ', upsilon = 'υ', phi = 'ϕ', varphi = 'φ', chi = 'χ',
    psi = 'ψ', omega = 'ω', digamma = 'ϝ',
    Gamma = 'Γ', Delta = 'Δ', Theta = 'Θ', Lambda = 'Λ', Xi = 'Ξ', Pi = 'Π', Sigma = 'Σ',
    Upsilon = 'Υ', Phi = 'Φ', Psi = 'Ψ', Omega = 'Ω',
    varGamma = 'Γ', varDelta = 'Δ', varTheta = 'Θ', varLambda = 'Λ', varXi = 'Ξ', varPi = 'Π',
    varSigma = 'Σ', varUpsilon = 'Υ', varPhi = 'Φ', varPsi = 'Ψ', varOmega = 'Ω',
    infty = '∞', partial = '∂', nabla = '∇', forall = '∀', exists = '∃', nexists = '∄',
    emptyset = '∅', varnothing = '∅', hbar = 'ℏ', hslash = 'ℏ', ell = 'ℓ', Re = 'ℜ', Im = 'ℑ',
    aleph = 'ℵ', beth = 'ℶ', wp = '℘', prime = '′', angle = '∠', measuredangle = '∡',
    triangle = '△', neg = '¬', lnot = '¬', top = '⊤', bot = '⊥', ldots = '…', dots = '…',
    dotsc = '…', dotso = '…', cdots = '⋯', dotsb = '⋯', dotsm = '⋯', dotsi = '⋯', vdots = '⋮',
    ddots = '⋱', degree = '°', checkmark = '✓', clubsuit = '♣', diamondsuit = '♢',
    heartsuit = '♡', spadesuit = '♠', flat = '♭', natural = '♮', sharp = '♯', surd = '√',
    imath = 'ı', jmath = 'ȷ', Box = '□', square = '□', blacksquare = '■', Diamond = '◊',
    lozenge = '◊', backslash = '∖', S = '§', P = '¶', copyright = '©', pounds = '£',
    vert = '|', Vert = '‖', mho = '℧', complement = '∁', eth = 'ð', star = '⋆',
    bigstar = '★', infin = '∞', AA = 'Å', aa = 'å', O = 'Ø', o = 'ø', ss = 'ß',
    dagger = '†', ddagger = '‡', textbackslash = '\\',
})

add('bin', {
    pm = '±', mp = '∓', times = '×', div = '÷', cdot = '⋅', cdotp = '⋅', centerdot = '⋅',
    ast = '∗', circ = '∘', bullet = '∙', oplus = '⊕', ominus = '⊖', otimes = '⊗', oslash = '⊘',
    odot = '⊙', cup = '∪', cap = '∩', sqcup = '⊔', sqcap = '⊓', vee = '∨', lor = '∨',
    wedge = '∧', land = '∧', setminus = '∖', smallsetminus = '∖', wr = '≀', uplus = '⊎',
    amalg = '⨿', diamond = '⋄', bigtriangleup = '△', bigtriangledown = '▽',
    triangleleft = '◃', triangleright = '▹', lhd = '⊲', rhd = '⊳', unlhd = '⊴', unrhd = '⊵',
    ltimes = '⋉', rtimes = '⋊', boxplus = '⊞', boxminus = '⊟', boxtimes = '⊠', boxdot = '⊡',
    dotplus = '∔', divideontimes = '⋇', barwedge = '⊼', veebar = '⊻', intercal = '⊺',
})

add('rel', {
    leq = '≤', le = '≤', geq = '≥', ge = '≥', neq = '≠', ne = '≠', equiv = '≡', approx = '≈',
    sim = '∼', simeq = '≃', cong = '≅', propto = '∝', ll = '≪', gg = '≫', lll = '⋘', ggg = '⋙',
    subset = '⊂', supset = '⊃', subseteq = '⊆', supseteq = '⊇', subsetneq = '⊊', supsetneq = '⊋',
    nsubseteq = '⊈', nsupseteq = '⊉', sqsubset = '⊏', sqsupset = '⊐', sqsubseteq = '⊑',
    sqsupseteq = '⊒', ['in'] = '∈', ni = '∋', owns = '∋', notin = '∉', perp = '⊥',
    parallel = '∥', nparallel = '∦', mid = '∣', nmid = '∤', vdash = '⊢', dashv = '⊣',
    models = '⊨', vDash = '⊨', Vdash = '⊩', nvdash = '⊬', nvDash = '⊭',
    to = '→', rightarrow = '→', gets = '←', leftarrow = '←', leftrightarrow = '↔',
    Rightarrow = '⇒', Leftarrow = '⇐', Leftrightarrow = '⇔', implies = '⟹', impliedby = '⟸',
    iff = '⟺', longrightarrow = '⟶', longleftarrow = '⟵', longleftrightarrow = '⟷',
    Longrightarrow = '⟹', Longleftarrow = '⟸', Longleftrightarrow = '⟺', mapsto = '↦',
    longmapsto = '⟼', uparrow = '↑', downarrow = '↓', updownarrow = '↕', Uparrow = '⇑',
    Downarrow = '⇓', Updownarrow = '⇕', nearrow = '↗', searrow = '↘', swarrow = '↙',
    nwarrow = '↖', hookrightarrow = '↪', hookleftarrow = '↩', rightleftharpoons = '⇌',
    leftrightharpoons = '⇋', rightharpoonup = '⇀', rightharpoondown = '⇁', leftharpoonup = '↼',
    leftharpoondown = '↽', rightleftarrows = '⇄', leftrightarrows = '⇆', twoheadrightarrow = '↠',
    rightsquigarrow = '⇝', leadsto = '⇝', coloneqq = '≔', coloneq = '≔', eqqcolon = '≕',
    doteq = '≐', asymp = '≍', bowtie = '⋈', Join = '⋈', prec = '≺', succ = '≻', preceq = '⪯',
    succeq = '⪰', lesssim = '≲', gtrsim = '≳', leqslant = '⩽', geqslant = '⩾', leqq = '≦',
    geqq = '≧', lneq = '⪇', gneq = '⪈', ncong = '≇', nsim = '≁', approxeq = '≊',
    triangleq = '≜', therefore = '∴', because = '∵', smile = '⌣', frown = '⌢', nleq = '≰',
    ngeq = '≱', nless = '≮', ngtr = '≯', lt = '<', gt = '>', sime = '≃', simeq = '≃',
    nequiv = '≢', propto = '∝', varpropto = '∝', between = '≬', pitchfork = '⋔',
    vartriangleleft = '⊲', vartriangleright = '⊳', Subset = '⋐', Supset = '⋑',
    circeq = '≗', bumpeq = '≏', Bumpeq = '≎', risingdotseq = '≓', fallingdotseq = '≒',
})

add('open', { langle = '⟨', lbrace = '{', lceil = '⌈', lfloor = '⌊', lvert = '|', lVert = '‖',
    lbrack = '[', lgroup = '⟮', ulcorner = '⌜', llcorner = '⌞' })
add('close', { rangle = '⟩', rbrace = '}', rceil = '⌉', rfloor = '⌋', rvert = '|', rVert = '‖',
    rbrack = ']', rgroup = '⟯', urcorner = '⌝', lrcorner = '⌟' })
add('punct', { colon = ':', ldotp = '.' })

-- Big operators. limits = scripts go above/below in display style.
local BIGOP = {
    sum = { '∑', true }, prod = { '∏', true }, coprod = { '∐', true }, bigcup = { '⋃', true },
    bigcap = { '⋂', true }, bigvee = { '⋁', true }, bigwedge = { '⋀', true },
    bigoplus = { '⨁', true }, bigotimes = { '⨂', true }, bigodot = { '⨀', true },
    biguplus = { '⨄', true }, bigsqcup = { '⨆', true },
    int = { '∫', false }, iint = { '∬', false }, iiint = { '∭', false }, oint = { '∮', false },
    oiint = { '∯', false }, oiiint = { '∰', false }, intop = { '∫', true }, smallint = { '∫', false },
}

-- Named functions rendered upright. true = takes limits in display style
local FUNCS = {
    sin = false, cos = false, tan = false, cot = false, sec = false, csc = false,
    arcsin = false, arccos = false, arctan = false, arccot = false, arcsec = false, arccsc = false,
    sinh = false, cosh = false, tanh = false, coth = false, sech = false, csch = false,
    log = false, ln = false, lg = false, exp = false, dim = false, ker = false, hom = false,
    deg = false, arg = false, th = false, sgn = false,
    det = true, gcd = true, lim = true, liminf = true, limsup = true, max = true, min = true,
    sup = true, inf = true, Pr = true, injlim = true, projlim = true, argmax = true, argmin = true,
}
local FUNC_TEXT = { liminf = 'lim inf', limsup = 'lim sup', injlim = 'inj lim', projlim = 'proj lim',
    argmax = 'arg max', argmin = 'arg min' }

-- Spacing commands, in em
local SPACES = {
    [','] = 3 / 18, [':'] = 4 / 18, ['>'] = 4 / 18, [';'] = 5 / 18, ['!'] = 0, [' '] = 0.25,
    quad = 1, qquad = 2, enspace = 0.5, thinspace = 3 / 18, medspace = 4 / 18,
    thickspace = 5 / 18, negthinspace = 0, negmedspace = 0, negthickspace = 0, enskip = 0.5,
    space = 0.25, nobreakspace = 0.25,
}

-- Accents drawn as a small glyph above the content
local ACCENTS = {
    hat = 'ˆ', widehat = 'ˆ', check = 'ˇ', widecheck = 'ˇ', tilde = '˜', widetilde = '˜',
    dot = '˙', ddot = '¨', dddot = '⋯', breve = '˘', acute = 'ˊ', grave = 'ˋ', vec = '→',
    overrightarrow = '→', overleftarrow = '←', overleftrightarrow = '↔', mathring = '˚',
}

-- Negated relations for \not
local NEGATE = {
    ['='] = '≠', ['<'] = '≮', ['>'] = '≯', ['∈'] = '∉', ['≡'] = '≢', ['⊂'] = '⊄', ['⊃'] = '⊅',
    ['⊆'] = '⊈', ['⊇'] = '⊉', ['≤'] = '≰', ['≥'] = '≱', ['∼'] = '≁', ['≅'] = '≇', ['≈'] = '≉',
    ['∣'] = '∤', ['∥'] = '∦', ['∃'] = '∄', ['≃'] = '≄', ['→'] = '↛', ['←'] = '↚', ['⇒'] = '⇏',
    ['⇔'] = '⇎', ['↔'] = '↮', ['⊢'] = '⊬', ['⊨'] = '⊭', ['∋'] = '∌',
}

-- Font styles for \mathbb, \mathcal, ... : map letters/digits to Unicode math alphanumerics.
-- Holes in the Unicode math blocks live in the Letterlike Symbols block.
local STYLE_BASE = {
    bf = { 0x1D400, 0x1D41A, 0x1D7CE }, it = { 0x1D434, 0x1D44E }, bb = { 0x1D538, 0x1D552, 0x1D7D8 },
    cal = { 0x1D49C, 0x1D4B6 }, frak = { 0x1D504, 0x1D51E }, sf = { 0x1D5A0, 0x1D5BA, 0x1D7E2 },
    tt = { 0x1D670, 0x1D68A, 0x1D7F6 }, bfit = { 0x1D468, 0x1D482 },
}
local STYLE_HOLES = {
    it = { h = 0x210E },
    bb = { C = 0x2102, H = 0x210D, N = 0x2115, P = 0x2119, Q = 0x211A, R = 0x211D, Z = 0x2124 },
    cal = { B = 0x212C, E = 0x2130, F = 0x2131, H = 0x210B, I = 0x2110, L = 0x2112, M = 0x2133,
        R = 0x211B, e = 0x212F, g = 0x210A, o = 0x2134 },
    frak = { C = 0x212D, H = 0x210C, I = 0x2111, R = 0x211C, Z = 0x2128 },
}

local function style_char(ch, style)
    local base = STYLE_BASE[style]
    if not base or #ch ~= 1 then return ch end
    local holes = STYLE_HOLES[style]
    if holes and holes[ch] then return U(holes[ch]) end
    local b = ch:byte()
    if b >= 65 and b <= 90 then return U(base[1] + b - 65) end
    if b >= 97 and b <= 122 then return U(base[2] + b - 97) end
    if b >= 48 and b <= 57 and base[3] then return U(base[3] + b - 48) end
    return ch
end
M.style_char = style_char

local STYLE_CMDS = {
    mathbb = 'bb', Bbb = 'bb', mathbf = 'bf', bf = 'bf', bold = 'bf', boldsymbol = 'bfit', bm = 'bfit',
    mathcal = 'cal', mathscr = 'cal', cal = 'cal', mathfrak = 'frak', frak = 'frak',
    mathit = 'it', it = 'it', mathsf = 'sf', sf = 'sf', mathtt = 'tt', tt = 'tt',
    mathrm = 'rm', rm = 'rm', mathup = 'rm',
}

local TEXT_CMDS = {
    text = true, textrm = true, textnormal = true, mbox = true, textit = true, textbf = true,
    textsf = true, texttt = true, textup = true, hbox = true, emph = true, textmd = true,
}

-- Commands that are ignored entirely (with the number of brace args to skip)
local IGNORED = {
    displaystyle = 0, textstyle = 0, scriptstyle = 0, scriptscriptstyle = 0, nonumber = 0,
    notag = 0, limits = 0, nolimits = 0, label = 1, tag = 1, ['tag*'] = 1, color = 1,
    vspace = 1, ['vspace*'] = 1, strut = 0, mathstrut = 0, allowbreak = 0, nobreak = 0,
    normalsize = 0, small = 0, large = 0, Large = 0, LARGE = 0, huge = 0,
    Huge = 0, tiny = 0, scriptsize = 0, footnotesize = 0, href = 1, mathchoice = 0,
}

local ENV_DELIMS = {
    pmatrix = { '(', ')' }, bmatrix = { '[', ']' }, Bmatrix = { '{', '}' }, vmatrix = { '|', '|' },
    Vmatrix = { '‖', '‖' }, cases = { '{', nil }, dcases = { '{', nil }, rcases = { nil, '}' },
    psmallmatrix = { '(', ')' }, bsmallmatrix = { '[', ']' },
}

local BIG_SIZES = { big = 1.2, Big = 1.6, bigg = 2.0, Bigg = 2.4 }

----------------------------------------------------------------------------
-- Parser
----------------------------------------------------------------------------
local Parser = {}
Parser.__index = Parser

function Parser:skip_ws()
    local _, e = self.s:find('^%s+', self.i)
    if e then self.i = e + 1 end
end

-- Returns the next token without consuming it.
function Parser:peek()
    local save, depth = self.i, self.cloze_depth
    local tok = self:next()
    self.i, self.cloze_depth = save, depth
    return tok
end

function Parser:next()
    self:skip_ws()
    local s = self.s
    while s:sub(self.i, self.i):match(cloze_marks) do
        self.cloze_depth = cloze_depth(self.cloze_depth, s:sub(self.i, self.i))
        self.i = self.i + 1
        self:skip_ws()
    end
    local i = self.i
    if i > #s then return nil end
    local c = s:sub(i, i)
    if c == '\\' then
        local name = s:match('^%a+', i + 1)
        if name then
            self.i = i + 1 + #name
            -- starred variants like \operatorname*
            if s:sub(self.i, self.i) == '*' and (name == 'operatorname' or name == 'tag') then
                self.i = self.i + 1
                name = name .. '*'
            end
            return { t = 'cmd', v = name }
        end
        local d = s:sub(i + 1, i + 1)
        if d == '' then
            self.i = i + 1
            return { t = 'char', v = '\\' }
        end
        local len = utf8_len_at(s, i + 1)
        self.i = i + 1 + len
        return { t = 'cmd', v = s:sub(i + 1, i + len) }
    elseif c == '{' or c == '}' or c == '^' or c == '_' or c == '&' then
        self.i = i + 1
        return { t = c }
    else
        local len = utf8_len_at(s, i)
        self.i = i + len
        return { t = 'char', v = s:sub(i, i + len - 1) }
    end
end

-- Read a raw brace group's contents (for \text, \operatorname, \begin, ...)
function Parser:raw_group()
    self:skip_ws()
    local s = self.s
    if s:sub(self.i, self.i) ~= '{' then
        -- single token argument
        local tok = self:next()
        if not tok then return '' end
        return tok.v or ''
    end
    local depth, j = 0, self.i
    while j <= #s do
        local c = s:sub(j, j)
        if c == '\\' then
            j = j + 1
        elseif c == '{' then
            depth = depth + 1
        elseif c == '}' then
            depth = depth - 1
            if depth == 0 then
                local content = s:sub(self.i + 1, j - 1)
                self.i = j + 1
                return content
            end
        end
        j = j + 1
    end
    local content = s:sub(self.i + 1)
    self.i = #s + 1
    return content
end

-- Optional [ ... ] argument; returns raw string or nil
function Parser:optional_arg()
    self:skip_ws()
    local s = self.s
    if s:sub(self.i, self.i) ~= '[' then return nil end
    local depth, j = 0, self.i + 1
    while j <= #s do
        local c = s:sub(j, j)
        if c == '{' then depth = depth + 1
        elseif c == '}' then depth = depth - 1
        elseif c == ']' and depth <= 0 then
            local content = s:sub(self.i + 1, j - 1)
            self.i = j + 1
            return content
        end
        j = j + 1
    end
    return nil
end

local function is_stop(tok, stops)
    if not tok then return true end
    if tok.t == '}' then return stops.brace end
    if tok.t == '&' then return stops.cell end
    if tok.t == 'cmd' then
        if tok.v == '\\' or tok.v == 'cr' then return stops.cell end
        if tok.v == 'right' then return stops.right end
        if tok.v == 'end' then return stops.cell end
    end
    return false
end

-- Parse a list of atoms until a stop token (which is NOT consumed).
function Parser:parse_list(stops)
    local list = {}
    while true do
        local tok = self:peek()
        if not tok then break end
        if is_stop(tok, stops) then break end

        local atom
        if tok.t == '}' or tok.t == '&' then
            self:next() -- stray, ignore
        elseif tok.t == 'cmd' and (tok.v == '\\' or tok.v == 'cr') then
            self:next()
            self:optional_arg()
            atom = { k = 'space', em = 0.5 }
        elseif tok.t == 'cmd' and tok.v == 'right' then
            self:next()
            self:read_delim()
        elseif tok.t == 'cmd' and tok.v == 'end' then
            self:next()
            self:raw_group()
        elseif tok.t == '^' or tok.t == '_' then
            atom = { k = 'group', list = {} }
        else
            atom = self:parse_atom()
        end

        if atom then
            atom = self:parse_scripts(atom)
            list[#list + 1] = atom
        end
    end
    return list
end

function Parser:parse_scripts(atom)
    local sup, sub
    while true do
        local tok = self:peek()
        if not tok then break end
        if tok.t == '^' then
            self:next()
            sup = sup or {}
            sup[#sup + 1] = self:parse_arg()
        elseif tok.t == '_' then
            self:next()
            sub = sub or {}
            sub[#sub + 1] = self:parse_arg()
        elseif tok.t == 'char' and tok.v == "'" then
            self:next()
            sup = sup or {}
            table.insert(sup, 1, { k = 'sym', text = '′', cls = 'ord' })
        elseif tok.t == 'cmd' and (tok.v == 'limits' or tok.v == 'nolimits') then
            self:next()
            atom.limits_override = (tok.v == 'limits')
        else
            break
        end
    end
    if sup or sub then
        return {
            k = 'scripts', base = atom,
            sup = sup and { k = 'group', list = sup } or nil,
            sub = sub and { k = 'group', list = sub } or nil,
        }
    end
    return atom
end

-- A single argument: a {group} or one atom
function Parser:parse_arg()
    local tok = self:peek()
    if not tok then return { k = 'group', list = {} } end
    if tok.t == '{' then
        self:next()
        local list = self:parse_list({ brace = true })
        local close = self:peek()
        if close and close.t == '}' then self:next() end
        return { k = 'group', list = list }
    end
    if tok.t == '}' or tok.t == '&' or tok.t == '^' or tok.t == '_' then
        return { k = 'group', list = {} }
    end
    return self:parse_atom() or { k = 'group', list = {} }
end

-- Delimiter after \left, \right, \big ...
function Parser:read_delim()
    local tok = self:next()
    if not tok then return nil end
    if tok.t == 'char' then
        if tok.v == '.' then return nil end
        if tok.v == '<' then return '⟨' end
        if tok.v == '>' then return '⟩' end
        return tok.v
    elseif tok.t == 'cmd' then
        if tok.v == '{' or tok.v == '}' then return tok.v end
        if tok.v == '|' then return '‖' end
        local sym = SYM[tok.v]
        if sym then return sym[1] end
        return nil
    end
    return nil
end

local CHAR_CLASS = {
    ['+'] = { '+', 'bin' }, ['-'] = { '−', 'bin' }, ['*'] = { '∗', 'bin' },
    ['='] = { '=', 'rel' }, ['<'] = { '<', 'rel' }, ['>'] = { '>', 'rel' }, [':'] = { ':', 'rel' },
    ['('] = { '(', 'open' }, ['['] = { '[', 'open' }, [')'] = { ')', 'close' }, [']'] = { ']', 'close' },
    [','] = { ',', 'punct' }, [';'] = { ';', 'punct' }, ['!'] = { '!', 'close' }, ['?'] = { '?', 'close' },
    ["'"] = { '′', 'ord' }, ['|'] = { '|', 'ord' }, ['/'] = { '/', 'ord' },
}

function Parser:char_atom(c)
    if c == '~' then return { k = 'space', em = 0.25 } end
    if c:match('^%a$') then return { k = 'sym', text = c, cls = 'ord', var = true } end
    local cc = CHAR_CLASS[c]
    if cc then return { k = 'sym', text = cc[1], cls = cc[2] } end
    return { k = 'sym', text = c, cls = 'ord' }
end

function Parser:parse_atom()
    local tok = self:next()
    if not tok then return nil end
    local highlighted = self.cloze_depth > 0
    local atom
    if tok.t == '{' then
        local list = self:parse_list({ brace = true })
        local close = self:peek()
        if close and close.t == '}' then self:next() end
        return { k = 'group', list = list }
    elseif tok.t == 'char' then
        atom = self:char_atom(tok.v)
    elseif tok.t == 'cmd' then
        atom = self:command(tok.v)
    end
    if atom then atom.highlighted = highlighted end
    return atom
end

function Parser:parse_env(name)
    local env = name:gsub('%*$', '')
    if env == 'array' or env == 'alignedat' or env == 'alignat' or env == 'subarray' then
        self:raw_group() -- column spec / column count
    end
    local rows, row = {}, {}
    while true do
        local cell = self:parse_list({ cell = true, brace = true })
        row[#row + 1] = { k = 'group', list = cell }
        local tok = self:next()
        if not tok then
            rows[#rows + 1] = row
            break
        elseif tok.t == '&' then
            -- next cell
        elseif tok.t == 'cmd' and (tok.v == '\\' or tok.v == 'cr') then
            self:optional_arg()
            rows[#rows + 1] = row
            row = {}
        elseif tok.t == 'cmd' and tok.v == 'end' then
            self:raw_group()
            rows[#rows + 1] = row
            break
        elseif tok.t == '}' then
            -- unbalanced brace inside environment; ignore it
        end
    end
    -- drop a trailing empty row (from a final \\)
    local last = rows[#rows]
    if #rows > 1 and #last == 1 and #last[1].list == 0 then rows[#rows] = nil end
    return { k = 'matrix', env = env, rows = rows }
end

function Parser:command(name)
    -- spacing
    if SPACES[name] then return { k = 'space', em = SPACES[name] } end

    -- escaped characters
    if name == '{' then return { k = 'sym', text = '{', cls = 'open' } end
    if name == '}' then return { k = 'sym', text = '}', cls = 'close' } end
    if name == '|' then return { k = 'sym', text = '‖', cls = 'ord' } end
    if name == '%' or name == '$' or name == '#' or name == '&' or name == '_' then
        return { k = 'sym', text = name, cls = 'ord' }
    end

    local sym = SYM[name]
    if sym then return { k = 'sym', text = sym[1], cls = sym[2] } end

    local op = BIGOP[name]
    if op then return { k = 'bigop', text = op[1], limits = op[2] } end

    if FUNCS[name] ~= nil then
        return { k = 'fn', text = FUNC_TEXT[name] or name, limits = FUNCS[name] }
    end

    if name == 'frac' or name == 'dfrac' or name == 'tfrac' or name == 'cfrac' then
        local num = self:parse_arg()
        local den = self:parse_arg()
        return { k = 'frac', num = num, den = den, size = (name == 'dfrac' or name == 'cfrac') and 'd' or (name == 'tfrac' and 't' or nil) }
    end
    if name == 'over' then
        -- infix \over is rare; render as a slash
        return { k = 'sym', text = '/', cls = 'ord' }
    end
    if name == 'binom' or name == 'dbinom' or name == 'tbinom' or name == 'choose' then
        if name == 'choose' then return { k = 'sym', text = 'C', cls = 'ord' } end
        local num = self:parse_arg()
        local den = self:parse_arg()
        return { k = 'frac', num = num, den = den, nobar = true, left = '(', right = ')',
            size = name == 'dbinom' and 'd' or (name == 'tbinom' and 't' or nil) }
    end
    if name == 'sqrt' then
        local idx = self:optional_arg()
        local body = self:parse_arg()
        return { k = 'sqrt', body = body, index = idx and M.parse(idx) or nil }
    end
    if TEXT_CMDS[name] then
        local raw = self:raw_group()
        for mark in raw:gmatch(cloze_marks) do self.cloze_depth = cloze_depth(self.cloze_depth, mark) end
        raw = raw:gsub('\\{', '\1'):gsub('\\}', '\2')            -- protect escaped braces
            :gsub('\\([%%%$#&_ ])', '%1'):gsub('\\%a+%s*', ''):gsub('[{}]', '')
            :gsub('\1', '{'):gsub('\2', '}')
        return { k = 'text', text = raw }
    end
    if name == 'operatorname' or name == 'operatorname*' then
        local raw = self:raw_group():gsub('\\', ''):gsub('[{}]', '')
        return { k = 'fn', text = raw, limits = (name == 'operatorname*') }
    end
    if STYLE_CMDS[name] ~= nil or name == 'mathnormal' then
        local body = self:parse_arg()
        return { k = 'style', style = STYLE_CMDS[name], body = body }
    end
    if ACCENTS[name] then
        return { k = 'accent', char = ACCENTS[name], body = self:parse_arg() }
    end
    if name == 'bar' or name == 'overline' or name == 'wideline' then
        return { k = 'overline', body = self:parse_arg() }
    end
    if name == 'underline' then
        return { k = 'underline', body = self:parse_arg() }
    end
    if name == 'overbrace' then
        return { k = 'overline', body = self:parse_arg(), limits = true, brace = true }
    end
    if name == 'underbrace' then
        return { k = 'underline', body = self:parse_arg(), limits = true, brace = true }
    end
    if name == 'overset' or name == 'stackrel' then
        local over = self:parse_arg()
        local body = self:parse_arg()
        return { k = 'stack', over = over, body = body }
    end
    if name == 'underset' then
        local under = self:parse_arg()
        local body = self:parse_arg()
        return { k = 'stack', under = under, body = body }
    end
    if name == 'xrightarrow' or name == 'xleftarrow' then
        local under = self:optional_arg()
        local over = self:parse_arg()
        return { k = 'stack', over = over, under = under and { k = 'group', list = M.parse(under) } or nil,
            body = { k = 'sym', text = name == 'xrightarrow' and '⟶' or '⟵', cls = 'rel' } }
    end
    if name == 'left' then
        local l = self:read_delim()
        local body = self:parse_list({ right = true })
        local r
        local tok = self:peek()
        if tok and tok.t == 'cmd' and tok.v == 'right' then
            self:next()
            r = self:read_delim()
        end
        return { k = 'leftright', left = l, right = r, body = { k = 'group', list = body } }
    end
    if name == 'middle' then
        local d = self:read_delim()
        return d and { k = 'sym', text = d, cls = 'ord' } or nil
    end
    do
        local base, suffix = name:match('^([bB]igg?)([lrm]?)$')
        if base then
            local d = self:read_delim()
            if not d then return nil end
            local cls = suffix == 'l' and 'open' or (suffix == 'r' and 'close' or 'ord')
            return { k = 'bigdelim', text = d, size = BIG_SIZES[base], cls = cls }
        end
    end
    if name == 'begin' then
        return self:parse_env(self:raw_group())
    end
    if name == 'not' then
        local nxt = self:parse_atom()
        if nxt and nxt.k == 'sym' then
            nxt.text = NEGATE[nxt.text] or (nxt.text .. U(0x0338))
            return nxt
        end
        return nxt
    end
    if name == 'pmod' then
        local x = self:parse_arg()
        return { k = 'group', list = { { k = 'space', em = 1 }, { k = 'sym', text = '(', cls = 'open' },
            { k = 'fn', text = 'mod' }, { k = 'space', em = 1 / 3 }, x, { k = 'sym', text = ')', cls = 'close' } } }
    end
    if name == 'bmod' or name == 'mod' then
        return { k = 'fn', text = 'mod', cls = 'bin' }
    end
    if name == 'hspace' or name == 'hspace*' or name == 'kern' or name == 'hskip' or name == 'mkern' then
        if name == 'hspace' then self:raw_group() end
        return { k = 'space', em = 0.5 }
    end
    if name == 'phantom' or name == 'hphantom' or name == 'vphantom' then
        return { k = 'phantom', body = self:parse_arg() }
    end
    if name == 'textcolor' or name == 'colorbox' then
        self:raw_group()
        return self:parse_arg()
    end
    if name == 'cancel' or name == 'bcancel' or name == 'xcancel' or name == 'boxed' or name == 'smash'
        or name == 'fbox' or name == 'cancelto' then
        if name == 'cancelto' then self:raw_group() end
        return self:parse_arg()
    end
    if IGNORED[name] then
        for _ = 1, IGNORED[name] do self:raw_group() end
        return nil
    end

    -- Unknown command: show it so the user can see what wasn't understood
    return { k = 'text', text = '\\' .. name, err = true }
end

function M.parse(tex, depth)
    local p = setmetatable({ s = tex or '', i = 1, cloze_depth = depth or 0 }, Parser)
    local list = {}
    -- parse_list stops on stray tokens like } / \right / & which we skip here
    while true do
        local part = p:parse_list({})
        for _, a in ipairs(part) do list[#list + 1] = a end
        local tok = p:peek()
        if not tok then break end
        p:next()
    end
    return list
end

----------------------------------------------------------------------------
-- Segmenting text into plain text / math
----------------------------------------------------------------------------
local DELIMS = {
    { open = '\\(', close = '\\)', display = false },
    { open = '\\[', close = '\\]', display = true },
    { open = '[$$]', close = '[/$$]', display = true },
    { open = '[$]', close = '[/$]', display = false },
}

-- Returns { {type='text', text=...} | {type='math', tex=..., display=bool}, ... }
function M.segment(str)
    local out = {}
    local pos = 1
    str = str or ''
    while pos <= #str do
        local best_s, best_d
        for _, d in ipairs(DELIMS) do
            local s = str:find(d.open, pos, true)
            if s and (not best_s or s < best_s) then best_s, best_d = s, d end
        end
        if not best_s then break end
        local cs, ce = str:find(best_d.close, best_s + #best_d.open, true)
        if not cs then break end
        if best_s > pos then out[#out + 1] = { type = 'text', text = str:sub(pos, best_s - 1) } end
        out[#out + 1] = { type = 'math', tex = str:sub(best_s + #best_d.open, cs - 1), display = best_d.display }
        pos = ce + 1
    end
    if pos <= #str then out[#out + 1] = { type = 'text', text = str:sub(pos) } end
    return out
end

-- { {start, finish}, ... } of math regions (delimiters included)
function M.segment_positions(str)
    local out = {}
    local pos = 1
    while pos <= #str do
        local best_s, best_d
        for _, d in ipairs(DELIMS) do
            local s = str:find(d.open, pos, true)
            if s and (not best_s or s < best_s) then best_s, best_d = s, d end
        end
        if not best_s then break end
        local _, ce = str:find(best_d.close, best_s + #best_d.open, true)
        if not ce then break end
        out[#out + 1] = { best_s, ce }
        pos = ce + 1
    end
    return out
end

----------------------------------------------------------------------------
-- Layout (needs the game: G, G.UIT, fonts)
----------------------------------------------------------------------------
local math_font_cache

function M.math_font()
    if math_font_cache then return math_font_cache end
    for _, f in ipairs(G.FONTS or {}) do
        if f.FONT and f.file and f.file:find('GoNotoCurrent', 1, true) then
            math_font_cache = f
            return f
        end
    end
    return G.LANG.font
end

local function measure(str, scale, font)
    str = str:gsub(M.cloze_placeholder, '[...]'):gsub(cloze_marks, '')
    local w = font.FONT:getWidth(str) * font.squish * scale * font.FONTSCALE / G.TILESIZE
    local h = font.FONT:getHeight() * scale * font.FONTSCALE * font.TEXT_HEIGHT_SCALE / G.TILESIZE
    return w, h
end
M.measure = measure

local function text_nodes(str, scale, font, colour)
    local nodes = {}
    local function add(text, tint)
        nodes[#nodes + 1] = { n = G.UIT.T, config = { text = text, scale = scale, font = font, colour = tint, shadow = false } }
    end
    local pos, depth = 1, 0
    local blue = colour == G.C.CLEAR and colour or G.C.BLUE
    for index, mark in str:gmatch('()([' .. M.cloze_placeholder .. M.cloze_start .. M.cloze_end .. '])') do
        if pos < index then add(str:sub(pos, index - 1), depth > 0 and blue or colour) end
        if mark == M.cloze_placeholder then add('[...]', blue) else depth = cloze_depth(depth, mark) end
        pos = index + 1
    end
    if pos <= #str then add(str:sub(pos), depth > 0 and blue or colour) end
    return nodes
end

-- Box constructors. A box is { node = <UI definition>, w = width, h = height, cls = class }
local function text_box(str, ctx, scale, cls)
    if str == '' then str = ' ' end
    scale = scale or ctx.scale
    local w, h = measure(str, scale, ctx.font)
    local nodes = text_nodes(str, scale, ctx.font, ctx.colour)
    return {
        node = #nodes == 1 and nodes[1] or { n = G.UIT.C, config = {align = 'cm'}, nodes = {
            { n = G.UIT.R, config = {align = 'cm', padding = 0}, nodes = nodes }
        }},
        w = w, h = h, cls = cls,
    }
end

local function spacer(w, h)
    return { node = { n = G.UIT.B, config = { w = math.max(w, 0), h = math.max(h, 0) } }, w = math.max(w, 0), h = math.max(h, 0), cls = 'space' }
end

local function rule(w, h, ctx)
    return { node = { n = G.UIT.B, config = { w = w, h = h, colour = ctx.colour } }, w = w, h = h, cls = 'ord' }
end

-- Horizontal list. A C node holding one R so it can be placed inside another row.
local function hbox(boxes, cls)
    local nodes, w, h = {}, 0, 0
    for _, b in ipairs(boxes) do
        nodes[#nodes + 1] = b.node
        w = w + b.w
        if b.h > h then h = b.h end
    end
    if #nodes == 0 then return spacer(0, 0) end
    return {
        node = { n = G.UIT.C, config = { align = 'cm', padding = 0 }, nodes = {
            { n = G.UIT.R, config = { align = 'cm', padding = 0 }, nodes = nodes } } },
        w = w, h = h, cls = cls or 'ord',
    }
end

-- Vertical stack. align: 'm' (centre), 'l' (left), 'r' (right)
local function vbox(boxes, align, cls)
    local rows, w, h = {}, 0, 0
    local ra = align == 'l' and 'cl' or (align == 'r' and 'cr' or 'cm')
    for _, b in ipairs(boxes) do
        rows[#rows + 1] = { n = G.UIT.R, config = { align = ra, padding = 0 }, nodes = { b.node } }
        h = h + b.h
        if b.w > w then w = b.w end
    end
    return {
        node = { n = G.UIT.C, config = { align = 'cm', padding = 0 }, nodes = rows },
        w = w, h = h, cls = cls or 'ord',
    }
end

local function line_height(ctx)
    local _, h = measure('(', ctx.scale, ctx.font)
    return h
end

local function child_ctx(ctx, changes)
    local c = {}
    for k, v in pairs(ctx) do c[k] = v end
    for k, v in pairs(changes) do c[k] = v end
    return c
end

local function smaller(ctx, ratio)
    return child_ctx(ctx, { scale = math.max(ctx.scale * ratio, ctx.min_scale), display = false, script = true })
end

-- Inter-atom spacing in em (simplified TeX rules)
local function spacing(prev, cur)
    if prev == 'rel' or cur == 'rel' then
        if prev == 'rel' and cur == 'rel' then return 0 end
        if prev == 'open' or cur == 'close' or prev == 'punct' then return 0 end
        return 5 / 18
    end
    if prev == 'bin' or cur == 'bin' then return 4 / 18 end
    if prev == 'punct' then return 3 / 18 end
    if prev == 'op' and (cur == 'ord' or cur == 'op' or cur == 'open' or cur == 'inner') then return 3 / 18 end
    if cur == 'op' and (prev == 'ord' or prev == 'close') then return 3 / 18 end
    return 0
end

local render_atom

local function render_list(list, ctx)
    local items = {}
    for _, atom in ipairs(list) do
        local b = render_atom(atom, ctx)
        if b then items[#items + 1] = b end
    end
    -- fix up binary operators that are really unary (e.g. leading minus)
    local prev
    for idx, b in ipairs(items) do
        if b.cls ~= 'space' then
            if b.cls == 'bin' then
                local nxt
                for j = idx + 1, #items do if items[j].cls ~= 'space' then nxt = items[j]; break end end
                if not prev or prev.cls == 'bin' or prev.cls == 'rel' or prev.cls == 'open'
                    or prev.cls == 'punct' or prev.cls == 'op' or not nxt
                    or nxt.cls == 'rel' or nxt.cls == 'close' or nxt.cls == 'punct' then
                    b.cls = 'ord'
                end
            end
            prev = b
        end
    end
    local boxes = {}
    prev = nil
    for _, b in ipairs(items) do
        if b.cls == 'space' then
            boxes[#boxes + 1] = b
        else
            if prev then
                local sp = spacing(prev.cls, b.cls)
                -- TeX drops bin/rel spacing in script size but keeps it around operators (\sin x)
                if ctx.script and prev.cls ~= 'op' and b.cls ~= 'op' then sp = 0 end
                if sp > 0 then boxes[#boxes + 1] = spacer(sp * ctx.scale, 0) end
            end
            boxes[#boxes + 1] = b
            prev = b
        end
    end
    if #boxes == 1 then return boxes[1] end
    return hbox(boxes, 'ord')
end

local function delim_box(text, ctx, target_h)
    local lh = line_height(ctx)
    local f = 1
    if target_h and target_h > lh * 1.15 then f = math.min(target_h / lh, 4) end
    return text_box(text, ctx, ctx.scale * f, 'ord')
end

local function apply_style(text, style, var)
    if style == 'rm' then return text end
    if style then return style_char(text, style) end
    if var then return style_char(text, 'it') end
    return text
end

local function render_matrix(atom, ctx)
    local env = atom.env
    local inner_ctx = child_ctx(ctx, { display = (env == 'aligned' or env == 'align' or env == 'gathered'
        or env == 'gather' or env == 'split' or env == 'eqnarray' or env == 'alignat' or env == 'alignedat'
        or env == 'flalign' or env == 'dcases') and ctx.display or false })
    if env == 'smallmatrix' or env == 'psmallmatrix' or env == 'bsmallmatrix' then
        inner_ctx = smaller(ctx, 0.7)
    end
    local is_align = env == 'aligned' or env == 'align' or env == 'split' or env == 'eqnarray'
        or env == 'alignat' or env == 'alignedat' or env == 'flalign'

    -- render cells
    local cells, ncols = {}, 0
    for r, row in ipairs(atom.rows) do
        cells[r] = {}
        for c, cell in ipairs(row) do
            local list = cell.list
            -- in aligned envs, the cell after & starts with a relation: add an empty ord so spacing applies
            if is_align and c % 2 == 0 and #list > 0 then
                list = { { k = 'sym', text = '', cls = 'ord', empty = true }, unpack(list) }
            end
            cells[r][c] = render_list(list, inner_ctx)
        end
        if #row > ncols then ncols = #row end
    end
    local row_h = {}
    for r, row in ipairs(cells) do
        row_h[r] = line_height(inner_ctx)
        for _, b in ipairs(row) do if b.h > row_h[r] then row_h[r] = b.h end end
    end
    local gap = 0.08 * ctx.scale
    local columns, total_w, total_h = {}, 0, 0
    for _, h in ipairs(row_h) do total_h = total_h + h + gap end
    for c = 1, ncols do
        local align
        if is_align then align = (c % 2 == 1) and 'cr' or 'cl'
        elseif env == 'cases' or env == 'dcases' or env == 'rcases' then align = 'cl'
        else align = 'cm' end
        local rows, col_w = {}, 0
        for r = 1, #cells do
            local b = cells[r][c] or spacer(0, 0)
            if b.w > col_w then col_w = b.w end
            rows[#rows + 1] = { n = G.UIT.R, config = { align = align, padding = 0, minh = row_h[r] + gap }, nodes = { b.node } }
        end
        if c > 1 then
            local sep
            if is_align then sep = (c % 2 == 0) and 0 or 1.0 else sep = 0.8 end
            if env == 'cases' or env == 'dcases' or env == 'rcases' then sep = 1.0 end
            if sep > 0 then
                columns[#columns + 1] = spacer(sep * inner_ctx.scale, 0).node
                total_w = total_w + sep * inner_ctx.scale
            end
        end
        columns[#columns + 1] = { n = G.UIT.C, config = { align = 'cm', padding = 0 }, nodes = rows }
        total_w = total_w + col_w
    end
    local grid = {
        node = { n = G.UIT.C, config = { align = 'cm', padding = 0 }, nodes = {
            { n = G.UIT.R, config = { align = 'cm', padding = 0 }, nodes = columns } } },
        w = total_w, h = total_h, cls = 'ord',
    }
    local delims = ENV_DELIMS[env]
    if not delims then return grid end
    local parts = {}
    if delims[1] then parts[#parts + 1] = delim_box(delims[1], ctx, total_h) end
    parts[#parts + 1] = spacer(0.1 * ctx.scale, 0)
    parts[#parts + 1] = grid
    parts[#parts + 1] = spacer(0.1 * ctx.scale, 0)
    if delims[2] then parts[#parts + 1] = delim_box(delims[2], ctx, total_h) end
    return hbox(parts, 'ord')
end

render_atom = function(atom, ctx)
    if atom.highlighted and ctx.colour ~= G.C.CLEAR then
        ctx = child_ctx(ctx, { colour = G.C.BLUE })
    end
    local k = atom.k
    if k == 'sym' then
        if atom.empty then
            local b = spacer(0, 0)
            b.cls = 'ord'
            return b
        end
        return text_box(apply_style(atom.text, ctx.style, atom.var), ctx, nil, atom.cls)
    elseif k == 'text' then
        local c = ctx
        if atom.err then c = child_ctx(ctx, { colour = G.C.RED }) end
        return text_box(atom.text, c, nil, 'ord')
    elseif k == 'fn' then
        return text_box(atom.text, ctx, nil, atom.cls or 'op')
    elseif k == 'bigop' then
        local f = ctx.display and 1.5 or 1.15
        return text_box(atom.text, ctx, ctx.scale * f, 'op')
    elseif k == 'space' then
        return spacer(atom.em * ctx.scale, 0)
    elseif k == 'group' then
        return render_list(atom.list, ctx)
    elseif k == 'style' then
        return render_atom(atom.body, child_ctx(ctx, { style = atom.style or false }))
    elseif k == 'phantom' then
        return render_atom(atom.body, child_ctx(ctx, { colour = G.C.CLEAR }))
    elseif k == 'frac' then
        local sub
        if atom.size == 'd' then
            sub = child_ctx(ctx, { display = false })
        elseif ctx.display and atom.size ~= 't' then
            sub = child_ctx(ctx, { display = false })
        else
            sub = smaller(ctx, M.FRAC_RATIO)
        end
        local num = render_atom(atom.num, sub)
        local den = render_atom(atom.den, sub)
        local w = math.max(num.w, den.w) + 0.15 * ctx.scale
        local thick = math.max(0.02, 0.06 * ctx.scale)
        local mid = atom.nobar and spacer(w, thick * 2) or rule(w, thick, ctx)
        local gap = 0.04 * ctx.scale
        local stack = vbox({ num, spacer(0, gap), mid, spacer(0, gap), den }, 'm', 'ord')
        local parts = {}
        if atom.left then parts[#parts + 1] = delim_box(atom.left, ctx, stack.h) end
        parts[#parts + 1] = spacer(0.05 * ctx.scale, 0)
        parts[#parts + 1] = stack
        parts[#parts + 1] = spacer(0.05 * ctx.scale, 0)
        if atom.right then parts[#parts + 1] = delim_box(atom.right, ctx, stack.h) end
        return hbox(parts, 'inner')
    elseif k == 'sqrt' then
        local body = render_atom(atom.body, ctx)
        local thick = math.max(0.02, 0.05 * ctx.scale)
        local over = vbox({ rule(body.w + 0.05 * ctx.scale, thick, ctx), spacer(0, 0.03 * ctx.scale), body }, 'l')
        local rad = delim_box('√', ctx, over.h)
        local parts = {}
        if atom.index then
            local idx = render_list(atom.index, smaller(ctx, 0.55))
            parts[#parts + 1] = vbox({ idx, spacer(0, rad.h * 0.35) }, 'r')
        end
        parts[#parts + 1] = rad
        parts[#parts + 1] = over
        return hbox(parts, 'ord')
    elseif k == 'scripts' then
        local base = render_atom(atom.base, ctx)
        -- Scripts go above/below for big operators in display style (\sum, \lim, ...),
        -- for \overbrace / \underbrace, or when forced with \limits / \nolimits.
        local b = atom.base
        local limits = false
        if b.k == 'bigop' or b.k == 'fn' then limits = (b.limits and ctx.display) or false
        elseif b.brace then limits = true end
        if b.limits_override ~= nil then limits = b.limits_override end
        local sctx = smaller(ctx, M.SCRIPT_RATIO)
        local sup = atom.sup and render_atom(atom.sup, sctx)
        local sub = atom.sub and render_atom(atom.sub, sctx)
        if limits then
            local parts = {}
            if sup then parts[#parts + 1] = sup end
            parts[#parts + 1] = base
            if sub then parts[#parts + 1] = sub end
            -- keep the base on the centre line by padding the shorter side
            local top = sup and sup.h or 0
            local bot = sub and sub.h or 0
            if top > bot then parts[#parts + 1] = spacer(0, top - bot)
            elseif bot > top then table.insert(parts, 1, spacer(0, bot - top)) end
            return vbox(parts, 'm', base.cls)
        end
        local col
        if sup and sub then
            col = vbox({ sup, spacer(0, base.h * 0.1), sub }, 'l')
        elseif sup then
            col = vbox({ sup, spacer(0, base.h * 0.4) }, 'l')
        else
            col = vbox({ spacer(0, base.h * 0.3), sub }, 'l')
        end
        return hbox({ base, spacer(0.02 * ctx.scale, 0), col }, base.cls)
    elseif k == 'leftright' then
        local body = render_atom(atom.body, ctx)
        local parts = {}
        if atom.left then parts[#parts + 1] = delim_box(atom.left, ctx, body.h) end
        parts[#parts + 1] = body
        if atom.right then parts[#parts + 1] = delim_box(atom.right, ctx, body.h) end
        return hbox(parts, 'inner')
    elseif k == 'bigdelim' then
        return text_box(atom.text, ctx, ctx.scale * atom.size, atom.cls)
    elseif k == 'accent' then
        local body = render_atom(atom.body, ctx)
        local acc = text_box(atom.char, ctx, ctx.scale * 0.6, 'ord')
        return vbox({ acc, body }, 'm', body.cls)
    elseif k == 'overline' then
        local body = render_atom(atom.body, ctx)
        local thick = math.max(0.02, 0.05 * ctx.scale)
        return vbox({ rule(body.w, thick, ctx), spacer(0, 0.03 * ctx.scale), body }, 'm', 'ord')
    elseif k == 'underline' then
        local body = render_atom(atom.body, ctx)
        local thick = math.max(0.02, 0.05 * ctx.scale)
        return vbox({ body, spacer(0, 0.03 * ctx.scale), rule(body.w, thick, ctx) }, 'm', 'ord')
    elseif k == 'stack' then
        local body = render_atom(atom.body, ctx)
        local sctx = smaller(ctx, M.SCRIPT_RATIO)
        local parts = {}
        local top, bot = 0, 0
        if atom.over then
            local o = render_atom(atom.over, sctx); parts[#parts + 1] = o; top = o.h
        end
        parts[#parts + 1] = body
        if atom.under then
            local u = render_atom(atom.under, sctx); parts[#parts + 1] = u; bot = u.h
        end
        if top > bot then parts[#parts + 1] = spacer(0, top - bot)
        elseif bot > top then table.insert(parts, 1, spacer(0, bot - top)) end
        return vbox(parts, 'm', body.cls)
    elseif k == 'matrix' then
        return render_matrix(atom, ctx)
    end
    return nil
end

-- Render a TeX string to a box
function M.render(tex, scale, display, colour, depth)
    local ctx = {
        scale = scale,
        min_scale = scale * M.MIN_RATIO,
        display = display,
        script = false,
        font = M.math_font(),
        colour = colour or G.C.WHITE,
        style = nil,
    }
    local ok, result = pcall(function()
        local list = M.parse(tex, depth)
        return render_list(list, ctx)
    end)
    if ok and result then return result end
    -- Fall back to the raw source if anything goes wrong
    if LOCAL_DEBUGGING or AKL_DEBUG then print('[ankilatro] MathJax render failed: ' .. tostring(result)) end
    return text_box(tex, child_ctx(ctx, { colour = G.C.RED }), nil, 'ord')
end

----------------------------------------------------------------------------
-- Wrapped text with inline / display math
----------------------------------------------------------------------------

-- Split text into tokens: words, math chunks and hard line breaks
local function tokenize(str, use_markdown)
    local tokens = {}
    local pending_space = ''
    local depth = 0
    local regions, parts = {}, {}
    local pos = 1
    for index, range in ipairs(M.segment_positions(str)) do
        local raw = str:sub(range[1], range[2])
        local segment = M.segment(raw)[1]
        segment.raw = raw
        regions[index] = segment
        parts[#parts + 1] = str:sub(pos, range[1] - 1)
        parts[#parts + 1] = '\30' .. index .. '\29'
        pos = range[2] + 1
    end
    parts[#parts + 1] = str:sub(pos)

    local function line_break()
        tokens[#tokens + 1] = { kind = 'break' }
        pending_space = ''
    end
    local function emit(s, styles, link)
        local code = styles:find('code', 1, true)
        local i = 1
        while i <= #s do
            local _, ws = s:find('^%s+', i)
            local index, after = s:match('^\30(%d+)\29()', i)
            local char = s:sub(i, i)
            if char:match(cloze_marks) then
                depth = cloze_depth(depth, char)
                i = i + 1
            elseif ws then
                local spaces = s:sub(i, ws)
                if spaces:find('\n', 1, true) then
                    line_break()
                else
                    pending_space = code and spaces:gsub('\t', '    ') or ' '
                end
                i = ws + 1
            elseif index and regions[tonumber(index)] then
                local region = regions[tonumber(index)]
                if code then
                    tokens[#tokens + 1] = { kind = 'word', text = region.raw, space = pending_space, styles = styles,
                        depth = depth, link = link }
                else
                    tokens[#tokens + 1] = { kind = region.display and 'display' or 'math', tex = region.tex, space = pending_space, depth = depth }
                end
                for mark in region.raw:gmatch(cloze_marks) do depth = cloze_depth(depth, mark) end
                pending_space = ''
                i = after
            else
                local e = (s:find('[%s\30' .. M.cloze_start .. M.cloze_end .. ']', i + 1) or (#s + 1)) - 1
                tokens[#tokens + 1] = { kind = 'word', text = s:sub(i, e), space = pending_space, styles = styles,
                    depth = depth, link = link }
                pending_space = ''
                i = e + 1
            end
        end
    end
    local source = table.concat(parts)
    if use_markdown then markdown.runs(source, emit, line_break) else emit(source, '') end
    return tokens
end
M.tokenize = tokenize

local function font_has_glyphs(font, str)
    if not font.FONT.hasGlyphs then return true end
    local ok, res = pcall(font.FONT.hasGlyphs, font.FONT, str)
    return not ok or res
end

-- Builds a UI column containing `text_content` wrapped to roughly `max_chars`
-- characters per line, with any MathJax rendered in place.
function M.create_text_node(text_content, max_chars, text_scale, options)
    options = options or {}
    text_scale = text_scale or 0.35
    local colour = options.colour or G.C.WHITE
    local tfont = G.LANG.font
    local mfont = M.math_font()
    local math_scale = text_scale * M.MATH_SCALE
    local max_w = options.width or measure(string.rep('x', max_chars or 70), text_scale, tfont)
    local space_w = measure(' ', text_scale, tfont)
    local padding = 0.08 * text_scale / 0.35

    local lines = {}
    local cur = { items = {}, w = 0, h = 0 }
    local function flush(allow_blank)
        if #cur.items > 0 or allow_blank then lines[#lines + 1] = cur end
        cur = { items = {}, w = 0, h = 0 }
    end
    local function place(item, space)
        local keep_indent = item.styles and item.styles:find('code', 1, true)
        local sp = (#cur.items > 0 or keep_indent) and space_w * #space or 0
        if #cur.items > 0 and cur.w + sp + item.w > max_w then
            flush()
            sp = 0
        end
        item.gap = sp
        item.spaces = sp > 0 and space or ''
        cur.items[#cur.items + 1] = item
        cur.w = cur.w + sp + item.w
        cur.h = math.max(cur.h, item.h)
    end

    for _, tok in ipairs(tokenize(text_content or '', options.markdown)) do
        if tok.kind == 'break' then
            flush(options.markdown and #lines > 0 and #lines[#lines].items > 0)
        elseif tok.kind == 'word' then
            local font = font_has_glyphs(tfont, (tok.text:gsub(M.cloze_placeholder, '[...]'))) and tfont or mfont
            local scale = (font == tfont) and text_scale or math_scale
            if tok.styles:find('heading', 1, true) then scale = scale * 1.17 end
            local w, h = measure(tok.text, scale, font)
            place({ kind = 'text', text = tok.text, font = font, scale = scale, w = w, h = h, styles = tok.styles,
                highlighted = tok.depth > 0, link = options.links and tok.link }, tok.space)
        elseif tok.kind == 'math' then
            local box = M.render(tok.tex, math_scale, false, colour, tok.depth)
            place({ kind = 'box', box = box, w = box.w, h = box.h }, tok.space)
        elseif tok.kind == 'display' then
            flush()
            local box = M.render(tok.tex, math_scale, true, colour, tok.depth)
            lines[#lines + 1] = { display = true, items = { { kind = 'box', box = box } }, w = box.w, h = box.h }
        end
    end
    flush()

    local rows = {}
    local width, height = 0, padding * 2
    for _, line in ipairs(lines) do
        local nodes = {}
        local run -- current text run being merged
        local function end_run()
            if run then
                local styles = run.styles
                local tint = colour
                if run.highlighted or styles:find('link', 1, true) then tint = G.C.BLUE
                elseif styles:find('code', 1, true) then tint = G.C.GOLD or colour
                elseif styles:find('quote', 1, true) then tint = G.C.UI.TEXT_INACTIVE or colour end
                for _, node in ipairs(text_nodes(run.text, run.scale, run.font, tint)) do
                    local c = node.config
                    c.akl_bold = styles:find('bold', 1, true)
                    c.akl_italic = styles:find('italic', 1, true)
                    c.akl_strike = styles:find('strike', 1, true)
                    if c.akl_bold or c.akl_italic or c.akl_strike then c.func = 'ankilatro_style_text' end
                    if run.link and run.link:match("^https?://") then
                        c.button, c.hover, c.akl_link = 'ankilatro_explainer_link', true, run.link
                    end
                    nodes[#nodes + 1] = node
                end
                run = nil
            end
        end
        for _, item in ipairs(line.items) do
            if item.kind == 'text' then
                if run and run.font == item.font and run.styles == item.styles and run.scale == item.scale and
                    run.highlighted == item.highlighted and run.link == item.link then
                    run.text = run.text .. item.spaces .. item.text
                else
                    end_run()
                    if item.gap > 0 then nodes[#nodes + 1] = spacer(item.gap, 0).node end
                    run = { text = item.text, font = item.font, scale = item.scale, styles = item.styles,
                        highlighted = item.highlighted, link = item.link }
                end
            else
                end_run()
                if item.gap and item.gap > 0 then nodes[#nodes + 1] = spacer(item.gap, 0).node end
                nodes[#nodes + 1] = item.box.node
            end
        end
        end_run()
        local row_padding = line.display and padding * 0.625 or 0
        local blank = #nodes == 0 and text_scale * 0.35 or 0
        width = math.max(width, line.w + row_padding * 2)
        local row_height = math.max(line.h, blank) + row_padding * 2 + padding
        height = height + row_height
        rows[#rows + 1] = {
            n = G.UIT.R,
            config = { align = options.left and not line.display and 'cl' or 'cm', padding = row_padding,
                minh = blank, maxw = max_w * 1.05, akl_height = row_height },
            nodes = nodes,
        }
    end

    return {
        n = G.UIT.C,
        config = { align = options.left and 'cl' or 'cm', padding = padding },
        nodes = rows,
    }, width + padding * 2, height
end

return M
