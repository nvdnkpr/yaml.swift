import Foundation

class Parser {
  let tokens: [TokenMatch]
  var index: Int = 0
  var aliases: [String: Yaml] = [:]

  init(_ tokens: [TokenMatch]) {
    self.tokens = tokens
  }

  func peek () -> TokenMatch {
    return tokens[index]
  }

  func advance () -> TokenMatch {
    let r = tokens[index]
    index += 1
    return r
  }

  func accept (type: TokenType) -> Bool {
    if peek().type == type {
      advance()
      return true
    }
    return false
  }

  func expect (type: TokenType, message: String) -> String? {
    if peek().type == type {
      advance()
      return nil
    }
    return "\(message), \(context(buildContext()))"
  }

  func buildContext (count: Int = 25) -> String {
    var text = ""
    while peek().type != .End {
      text += advance().match
      if countElements(text) >= count {
        break
      }
    }
    return text
  }

  func ignoreSpace () {
    while contains([.Comment, .Space, .BlankLine, .NewLine], peek().type) {
      advance()
    }
  }

  func ignoreWhiteSpace () {
    while contains([.Comment, .Space, .BlankLine, .NewLine, .Indent, .Dedent], peek().type) {
      advance()
    }
  }

  func ignoreDocEnd () {
    while contains([.Comment, .Space, .BlankLine, .NewLine, .DocEnd], peek().type) {
      advance()
    }
  }

  func parse () -> Yaml {
    switch peek().type {

    case .Comment, .Space, .BlankLine, .NewLine:
      advance()
      return parse()

    case .Null:
      advance()
      return .Null

    case .True:
      advance()
      return .Bool(true)

    case .False:
      advance()
      return .Bool(false)

    case .Int:
      let m = advance().match as NSString
      return .Int(m.integerValue) // will be between Int.min and Int.max

    case .IntOct:
      let m = advance().match.stringByReplacingOccurrencesOfString("0o", withString: "")
      return .Int(parseInt(m, radix: 8)) // will throw runtime error if overflows

    case .IntHex:
      let m = advance().match.stringByReplacingOccurrencesOfString("0x", withString: "")
      return .Int(parseInt(m, radix: 16)) // will throw runtime error if overflows

    case .IntSex:
      let m = advance().match
      return .Int(parseInt(m, radix: 60))

    case .InfinityP:
      advance()
      return .Double(Double.infinity)

    case .InfinityN:
      advance()
      return .Double(-Double.infinity)

    case .NaN:
      advance()
      return .Double(Double.NaN)

    case .Double:
      let m = advance().match as NSString
      return .Double(m.doubleValue)

    case .Dash:
      return parseBlockSeq()

    case .OpenSB:
      return parseFlowSeq()

    case .OpenCB:
      return parseFlowMap()

    case .KeyDQ, .KeySQ, .Key, .QuestionMark:
      return parseBlockMap()

    case .Indent:
      accept(.Indent)
      let result = parse()
      if let error = expect(.Dedent, message: "expected dedent") {
        return .Invalid(error)
      }
      return result

    case .StringDQ, .StringSQ:
      let m = advance().match
      let r = Range(start: Swift.advance(m.startIndex, 1), end: Swift.advance(m.endIndex, -1))
      return .String(m.substringWithRange(r))

    case .String:
      return .String(advance().match)

    case .Anchor:
      let m = advance().match
      let name = m.substringFromIndex(Swift.advance(m.startIndex, 1))
      let value = parse()
      aliases[name] = value
      return value

    case .Alias:
      let m = advance().match
      let name = m.substringFromIndex(Swift.advance(m.startIndex, 1))
      return aliases[name] ?? .Null

    case .End:
      return .Null

    default:
      return .Invalid(context(buildContext()))

    }
  }

  func parseBlockSeq () -> Yaml {
    var seq: [Yaml] = []
    while accept(.Dash) {
      accept(.Indent)
      ignoreSpace()
      let v = parse()
      ignoreSpace()
      if let error = expect(.Dedent, message: "expected dedent after dash indent") {
        return .Invalid(error)
      }
      switch v {
      case .Invalid:
        return v
      default:
        seq.append(v)
      }
      ignoreSpace()
    }
    return .Array(seq)
  }

  func parseFlowSeq () -> Yaml {
    var seq: [Yaml] = []
    accept(.OpenSB)
    while !accept(.CloseSB) {
      ignoreSpace()
      if seq.count > 0 {
        if let error = expect(.Comma, message: "expected comma") {
          return .Invalid(error)
        }
      }
      ignoreSpace()
      let v = parse()
      switch v {
      case .Invalid:
        return v
      default:
        seq.append(v)
      }
      ignoreSpace()
    }
    return .Array(seq)
  }

  func parseFlowMap () -> Yaml {
    var map: [Yaml: Yaml] = [:]
    accept(.OpenCB)
    while !accept(.CloseCB) {
      ignoreWhiteSpace()
      if map.count > 0 {
        if let error = expect(.Comma, message: "expected comma") {
          return .Invalid(error)
        }
      }
      ignoreWhiteSpace()
      var k: Yaml
      switch peek().type {
      case .Key:
        k = .String(advance().match)
      case .KeyDQ, .KeySQ:
        k = .String(unwrapQuotedString(advance().match))
      default:
        return .Invalid(expect(.Key, message: "expected key")!)
      }
      if let error = expect(.Colon, message: "expected colon") {
        return .Invalid(error)
      }
      let v = parse()
      switch v {
      case .Invalid:
        return v
      default:
        map.updateValue(v, forKey: k)
      }
      ignoreWhiteSpace()
    }
    return .Dictionary(map)
  }

  func parseBlockMap () -> Yaml {
    var map: [Yaml: Yaml] = [:]
    while contains([.Key, .KeyDQ, .KeySQ, .QuestionMark], peek().type) {
      var k: Yaml
      switch peek().type {
      case .QuestionMark:
        advance()
        k = parse()
        switch k {
        case .Invalid:
          return k
        default:
          break
        }
        ignoreSpace()
        if peek().type != .Colon {
          map.updateValue(.Null, forKey: k)
          continue
        }
      case .Key:
        k = .String(advance().match)
      case .KeyDQ, .KeySQ:
        k = .String(unwrapQuotedString(advance().match))
      default:
        return .Invalid(expect(.Key, message: "expected key")!)
      }
      if let error = expect(.Colon, message: "expected colon") {
        return .Invalid(error)
      }
      ignoreSpace()
      var v: Yaml
      if accept(.Indent) {
        v = parse()
        if let error = expect(.Dedent, message: "expected dedent") {
          return .Invalid(error)
        }
      } else {
        v = parse()
      }
      switch v {
      case .Invalid:
        return v
      default:
        map.updateValue(v, forKey: k)
      }
      ignoreSpace()
    }
    return .Dictionary(map)
  }
}

func parseInt (s: String, #radix: Int) -> Int {
  if radix == 60 {
    return reduce(s.componentsSeparatedByString(":").map {
      $0.toInt()!
    }, 0, {$0 * radix + $1})
  } else {
    return reduce(lazy(s.unicodeScalars).map {
      c in
      switch c {
      case "0"..."9":
        return c.value - UnicodeScalar("0").value
      case "a"..."z":
        return c.value - UnicodeScalar("a").value + 10
      case "A"..."Z":
        return c.value - UnicodeScalar("A").value + 10
      default:
        fatalError("invalid digit")
      }
    }, 0, {$0 * radix + $1})
  }
}

func unwrapQuotedString (s: String) -> String {
  return s.substringWithRange(Range(start: advance(s.startIndex, 1), end: advance(s.endIndex, -1)))
}
