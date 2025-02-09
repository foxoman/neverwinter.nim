import strutils, algorithm, os, streams, json, sequtils, logging, times, tables, sets, strutils, std/sha1
export strutils, algorithm, os, streams, json, sequtils, logging, times, tables, sets, strutils

import neverwinter/util, neverwinter/resman,
  neverwinter/resref, neverwinter/key,
  neverwinter/resfile, neverwinter/resmemfile, neverwinter/resdir,
  neverwinter/resnwsync,
  neverwinter/erf, neverwinter/gff, neverwinter/gffjson,
  neverwinter/languages, neverwinter/compressedbuf,
  neverwinter/exo,
  neverwinter/game

# The things we do to cut down import hassle in tools.
# Should clean this up at some point and let the utils deal with it.
export util, resman, resref, key, resfile, resmemfile, resdir, erf, gff, gffjson,
  languages, compressedbuf, exo, game

import version

when defined(profiler):
  import nimprof

when not defined(nwnNoSharedLogger):
  addHandler newFileLogger(stderr, fmtStr = "$levelid [$datetime] ")

import docopt as docopt_internal
export docopt_internal

const GlobalUsage = """
  $0 -h | --help
  $0 --version
""".strip

# Options common to ALL utilities
let GlobalOpts = """

Logging:
  --verbose                   Turn on debug logging
  --quiet                     Turn off all logging except errors
  --version                   Show program version and licence info

Encoding:
  --nwn-encoding CHARSET      Sets the nwn encoding [default: """ & getNwnEncoding() & """]
  --other-encoding CHARSET    Sets the "other" file formats encoding, where
                              supported; see docs. Defaults to your current
                              shell/platform charset: [default: """ & getNativeEncoding() & """]
Resources:
  --add-restypes TUPLES       Add a restype. TUPLES is a comma-separated list
                              of colon-separated restypes. You do not need to do this
                              unless you want to handle files NWN does not know about
                              yet.
                              Example: txt:10,mdl:2002
"""

# Options common to utilities working with a resman.
let ResmanOpts = """

Resman:
  --root ROOT                 Override NWN root (autodetection is attempted)
  --userdirectory USERDIR     Override NWN user directory (autodetection is attempted)

  --no-keys                   Do not load keys into resman (ignore --keys)
  --keys KEYS                 key files to load (from root:data/)
                              [default: autodetect]
                              Will auto-detect if you are using a 1.69 or 1.8
                              layout.
  --no-ovr                    Do not load ovr/ in resman

  --language LANG             Load language overrides [default: en]

  --manifests MANIFESTS       Load comma-separated NWSync manifests [default: ]
  --erfs ERFS                 Load comma-separated erf files [default: ]
  --dirs DIRS                 Load comma-separated directories [default: ]
""" & GlobalOpts

var Args: Table[string, docopt_internal.Value]

proc DOC*(body: string): Table[string, docopt_internal.Value] =
  let body2 = body.replace("$USAGE", GlobalUsage).
                   replace("$0", getAppFilename().extractFilename()).
                   replace("$OPTRESMAN", ResmanOpts).
                   replace("$OPT", GlobalOpts)

  result = docopt_internal.docopt(body2)
  Args = result

  if Args["--version"]:
    printVersion()
    quit()

  if Args.hasKey("--verbose") and Args["--verbose"]: setLogFilter(lvlDebug)
  elif Args.hasKey("--quiet") and Args["--quiet"]: setLogFilter(lvlError)
  else: setLogFilter(lvlInfo)

  setNwnEncoding($Args["--nwn-encoding"])
  setNativeEncoding($Args["--other-encoding"])

  debug("NWN file encoding: " & getNwnEncoding())
  debug("Other file encoding: " & getNativeEncoding())

  if Args.hasKey("--add-restypes") and Args["--add-restypes"]:
    let types = ($Args["--add-restypes"]).split(",").mapIt(it.split(":"))
    for ty in types:
      if ty.len != 2:
        raise newException(ValueError,
          "Could not parse --add-restypes: '" & ($Args["--add-restypes"]) & "'")

      let (rt, ext) = (ty[1].parseInt, ty[0])

      if rt < low(uint16).int or rt > high(uint16).int:
        raise newException(ValueError, "Integer " & $rt & " out of range for ResType")

      registerCustomResType(ResType rt, ext)
      debug "Registering custom ResType ", ext, " -> ", rt

proc newBasicResMan*(
    root = findNwnRoot(if Args["--root"]: $Args["--root"] else: ""),
    user = findUserRoot(if Args["--userdirectory"]: $Args["--userdirectory"] else: ""),
    language = "", cacheSize = 0): ResMan =
  ## Sets up a resman that defaults to what EE looks like.
  ## Will load an additional language directory, if language is given.
  newDefaultResMan(root, user, language, cacheSize)

proc ensureValidFormat*(format, filename: string,
                       supportedFormats: Table[string, seq[string]]): string =
  result = format
  if result == "autodetect" and filename != "-":
    let ext = splitFile(filename).ext.strip(true, false, {'.'})
    for fmt, exts in supportedFormats:
      if exts.contains(ext):
        result = fmt
        break

  if result == "autodetect":
    quit("Cannot detect file format from filename: " & filename)

  if not supportedFormats.hasKey(result):
    quit("Not a supported file format: " & result)

iterator filterByMatch*(rm: ResMan, patternMatch: string, binaryMatch: string, invert: bool): Res =
  for o in rm.contents:
    let str = $o
    let res = rm[o].get()

    let match = (patternMatch != "" and str.find(patternMatch) != -1) or
                (binaryMatch != "" and res.readAll().find(binaryMatch) != -1)

    if (match and not invert) or (not match and invert):
      yield(res)
