import Foundation

/// OCR 文本解析结果
struct ParsedReceipt: Equatable {
    var amount: Double?
    var isIncome: Bool = false
    var merchant: String?
    var date: Date?
    var categoryName: String?
    var rawText: String = ""
}

/// 从支付截图 / 小票 / 银行短信的 OCR 文本中提取金额、商户、时间并猜测分类。
/// 纯 Foundation 实现，不依赖 Apple 专有框架，可在 Linux 上做单元检查（见 Tools/ParserCheck）。
enum ReceiptParser {

    // MARK: - 公共入口

    static func parse(lines rawLines: [String], now: Date = Date(), calendar: Calendar = .current) -> ParsedReceipt {
        let lines = rawLines
            .map { normalize($0) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var result = ParsedReceipt()
        result.rawText = lines.joined(separator: "\n")

        let candidates = amountCandidates(lines: lines)
        let best = candidates.max { a, b in
            if a.score == b.score { return a.lineIndex > b.lineIndex } // 同分取靠上的
            return a.score < b.score
        }
        if let best, best.score > -20 {
            result.amount = (best.value * 100).rounded() / 100
        }

        // 收入 / 支出
        let fullText = lines.joined(separator: " ")
        if let best, best.sign == "-" {
            result.isIncome = false
        } else if let best, best.sign == "+" {
            result.isIncome = true
        } else {
            result.isIncome = incomeKeywords.contains { fullText.contains($0) }
        }

        result.merchant = merchant(lines: lines, amountLineIndex: best?.lineIndex)
        result.date = date(lines: lines, now: now, calendar: calendar)

        if let m = result.merchant, let c = CategoryGuesser.guess(text: m, isIncome: result.isIncome) {
            result.categoryName = c
        } else {
            result.categoryName = CategoryGuesser.guess(text: fullText, isIncome: result.isIncome)
        }
        return result
    }

    // MARK: - 规范化

    static func normalize(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "：": out.append(":")
            case "，": out.append(",")
            case "．": out.append(".")
            case "－", "—", "–", "−": out.append("-")
            case "＋": out.append("+")
            case "￥": out.append("¥")
            case "（": out.append("(")
            case "）": out.append(")")
            case "　": out.append(" ")
            default:
                if let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1,
                   scalar.value >= 0xFF10, scalar.value <= 0xFF19,
                   let half = Unicode.Scalar(scalar.value - 0xFF10 + 0x30) {
                    out.unicodeScalars.append(half) // 全角数字
                } else {
                    out.append(ch)
                }
            }
        }
        // "23. 50" / "23 .50" -> "23.50"
        out = replace(#"(\d)\s*\.\s+(\d)"#, in: out, with: "$1.$2")
        out = replace(#"(\d)\s+\.(\d)"#, in: out, with: "$1.$2")
        return out
    }

    // MARK: - 金额

    struct AmountCandidate: Equatable {
        var value: Double
        var score: Double
        var lineIndex: Int
        var sign: String   // "+", "-", ""
    }

    static let strongKeywords = ["实付款", "实付金额", "实付", "实收金额", "实收", "付款金额", "支付金额", "交易金额",
                                 "消费金额", "订单金额", "应付金额", "应付", "合计", "总计", "总金额", "总价",
                                 "支出金额", "转账金额", "收款金额", "到账金额", "退款金额", "扣款金额"]
    static let weakKeywords = ["金额", "价格", "消费", "支出", "付款", "支付", "交易", "扣款", "收款", "到账", "人民币"]
    static let negativeKeywords = ["优惠", "折扣", "立减", "减免", "抵扣", "积分", "余额", "可用", "限额", "额度",
                                   "原价", "运费", "配送费", "包装费", "手续费", "找零", "返现", "券", "满", "单价",
                                   "数量", "已省", "节省", "共省"]
    static let countSuffixes: Set<Character> = ["件", "个", "次", "份", "张", "笔", "位", "人", "天", "期", "号", "楼", "室", "%", "折", "斤", "克", "g", "G", "k", "K", "m", "M"]

    private static let amountPattern = try! NSRegularExpression(
        pattern: #"(?<![\d.,])([+\-]?)\s*(¥|RMB|CNY|人民币)?\s*([+\-]?)\s*(\d{1,3}(?:,\d{3})+|\d+)(\.\d{1,2})?(?![\d.])\s*(元)?"#)

    private static let removalPatterns: [NSRegularExpression] = [
        #"20\d{2}\s*[-/.年]\s*\d{1,2}\s*[-/.月]\s*\d{1,2}\s*日?"#,
        #"\d{1,2}\s*月\s*\d{1,2}\s*日"#,
        #"\d{1,2}:\d{2}(?::\d{2})?"#,
        #"[A-Za-z0-9]{13,}"#,
        #"\d{9,}"#,
        #"(尾号|卡号|末四位|账户|账号|卡)\s*\(?\s*\*{0,4}\d{3,4}\)?"#,
        #"\(\s*\d{4}\s*\)"#,
        #"\d+(?:\.\d+)?\s*%"#,
        #"[x×X*]\s*\d+"#,
        #"\d+\s*[x×X*]"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    static func cleanForAmounts(_ line: String) -> String {
        var s = line
        for re in removalPatterns {
            let ns = s as NSString
            s = re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: ns.length), withTemplate: " ")
        }
        return s
    }

    static func amountCandidates(lines: [String]) -> [AmountCandidate] {
        var all: [AmountCandidate] = []
        var lineHadCandidates = [Bool](repeating: false, count: lines.count)

        for (index, line) in lines.enumerated() {
            let cleaned = cleanForAmounts(line)
            let ns = cleaned as NSString
            let matches = amountPattern.matches(in: cleaned, range: NSRange(location: 0, length: ns.length))
            var previousEnd = 0
            var lineCandidates: [AmountCandidate] = []

            for m in matches {
                let intPart = group(m, 4, ns).replacingOccurrences(of: ",", with: "")
                let decPart = group(m, 5, ns)
                guard let value = Double(intPart + decPart), value > 0 else { previousEnd = m.range.location + m.range.length; continue }

                let sign1 = group(m, 1, ns), sign2 = group(m, 3, ns)
                let sign = !sign1.isEmpty ? sign1 : sign2
                let hasCurrency = !group(m, 2, ns).isEmpty || !group(m, 6, ns).isEmpty

                let labelRange = NSRange(location: previousEnd, length: max(0, m.range.location - previousEnd))
                var label = ns.substring(with: labelRange)
                if group(m, 2, ns) == "人民币" { label += "人民币" }
                previousEnd = m.range.location + m.range.length

                var score: Double = 0
                var hasKeyword = false

                if strongKeywords.contains(where: { label.contains($0) }) {
                    score += 60; hasKeyword = true
                } else if weakKeywords.contains(where: { label.contains($0) }) {
                    score += 30; hasKeyword = true
                }
                // 标签与金额分行（如「实付款」下一行是「¥20.00」）
                if !hasKeyword, lineCandidates.isEmpty, label.trimmingCharacters(in: .whitespaces).count <= 1,
                   index > 0, !lineHadCandidates[index - 1] {
                    let prev = lines[index - 1]
                    if strongKeywords.contains(where: { prev.contains($0) }) { score += 45; hasKeyword = true }
                    else if weakKeywords.contains(where: { prev.contains($0) }) { score += 20; hasKeyword = true }
                    if negativeKeywords.contains(where: { prev.contains($0) }) { score -= 30 }
                }
                // 只看紧邻金额前面的一小段做负向判断，避免整行误伤
                let nearLabel = String(label.suffix(8))
                if negativeKeywords.contains(where: { nearLabel.contains($0) }) { score -= 45 }

                if hasCurrency { score += 30 }
                if decPart.count == 3 { score += 20 } else if decPart.count == 2 { score += 10 }
                if sign == "-" || sign == "+" { score += 25 }

                // 整行只有这个金额（微信/支付宝支付成功页的大字金额）
                let rest = ns.replacingCharacters(in: m.range, with: "")
                    .trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":-+")))
                if rest.isEmpty { score += 20 }

                if decPart.isEmpty && !hasCurrency {
                    score -= 15
                    if !hasKeyword { score -= 10 }
                    if value >= 1900 && value <= 2100 { score -= 30 }
                }
                // 紧跟量词：「共3件」「2人」
                let afterLoc = m.range.location + m.range.length
                if afterLoc < ns.length {
                    let after = ns.substring(from: afterLoc).trimmingCharacters(in: .whitespaces)
                    if let c = after.first, countSuffixes.contains(c), !hasCurrency { score -= 50 }
                }
                if value > 1_000_000 { score -= 60 }
                score -= Double(index) * 0.3

                lineCandidates.append(AmountCandidate(value: value, score: score, lineIndex: index, sign: sign))
            }
            lineHadCandidates[index] = !lineCandidates.isEmpty
            all.append(contentsOf: lineCandidates)
        }
        return all
    }

    // MARK: - 商户

    static let merchantKeywords = ["商户全称", "商户名称", "商家名称", "收款方全称", "收款商户", "收款方", "收款人",
                                   "交易对方", "对方账户", "对方户名", "商品说明", "商品名称", "付款给", "转账给",
                                   "店铺名称", "门店名称", "商户", "商家", "店铺", "门店", "对方"]
    static let merchantBlacklist = ["支付成功", "付款成功", "交易成功", "支付完成", "账单详情", "交易详情", "完成",
                                    "当前状态", "返回", "已支付", "订单详情", "转账成功", "收款成功", "收款到账",
                                    "已收款", "数量", "单价", "金额", "合计", "实付", "支付方式", "付款方式",
                                    "账单分类", "订单号", "交易单号", "商户单号", "支付时间", "交易时间", "创建时间",
                                    "备注", "查看", "联系", "申请", "电子小票", "全部账单", "微信支付", "支付宝",
                                    "待收货", "已完成", "零钱", "储蓄卡", "信用卡"]

    static func merchant(lines: [String], amountLineIndex: Int?) -> String? {
        for key in merchantKeywords {
            for (i, line) in lines.enumerated() {
                guard let r = line.range(of: key) else { continue }
                // 关键词需位于行首附近（避免「请向商家确认」之类）
                guard line.distance(from: line.startIndex, to: r.lowerBound) <= 2 else { continue }
                var value = String(line[r.upperBound...])
                value = cleanMerchant(value)
                if value.isEmpty, i + 1 < lines.count { value = cleanMerchant(lines[i + 1]) }
                if isPlausibleMerchant(value) { return value }
            }
        }
        // 兜底：从金额所在行往上找第一行像名称的文本
        if let idx = amountLineIndex, idx > 0 {
            for i in stride(from: idx - 1, through: 0, by: -1) {
                let v = cleanMerchant(lines[i])
                if isPlausibleMerchant(v) { return v }
            }
        }
        // 再往下看两行（「订单金额 ¥1299」下一行才是商户的情况）
        if let idx = amountLineIndex {
            for i in (idx + 1)..<min(idx + 3, lines.count) {
                let v = cleanMerchant(lines[i])
                if isPlausibleMerchant(v) { return v }
            }
        }
        return nil
    }

    private static func cleanMerchant(_ s: String) -> String {
        var v = s.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: ":>›〉》|")))
        if v.count > 30 { v = String(v.prefix(30)) }
        return v
    }

    private static func isPlausibleMerchant(_ s: String) -> Bool {
        guard s.count >= 2, s.count <= 30 else { return false }
        if merchantBlacklist.contains(where: { s.contains($0) }) { return false }
        let digits = s.filter { $0.isNumber }.count
        if digits >= 3 { return false }
        let letters = s.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        return letters >= 2
    }

    // MARK: - 日期

    private static let fullDatePattern = try! NSRegularExpression(
        pattern: #"(20\d{2})\s*[-/.年]\s*(\d{1,2})\s*[-/.月]\s*(\d{1,2})\s*日?\s*(?:(\d{1,2}):(\d{2})(?::(\d{2}))?)?"#)
    private static let monthDayPattern = try! NSRegularExpression(
        pattern: #"(\d{1,2})\s*月\s*(\d{1,2})\s*日\s*(?:(\d{1,2}):(\d{2}))?"#)
    private static let relativePattern = try! NSRegularExpression(
        pattern: #"(今天|昨天|前天)\s*(\d{1,2}):(\d{2})"#)

    static func date(lines: [String], now: Date, calendar: Calendar) -> Date? {
        let text = lines.joined(separator: "\n")
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        let latest = now.addingTimeInterval(2 * 86_400)

        if let m = fullDatePattern.firstMatch(in: text, range: range) {
            var c = DateComponents()
            c.year = Int(group(m, 1, ns)); c.month = Int(group(m, 2, ns)); c.day = Int(group(m, 3, ns))
            c.hour = Int(group(m, 4, ns)) ?? 12; c.minute = Int(group(m, 5, ns)) ?? 0; c.second = Int(group(m, 6, ns)) ?? 0
            if valid(c), let d = calendar.date(from: c), d <= latest { return d }
        }
        if let m = monthDayPattern.firstMatch(in: text, range: range) {
            var c = DateComponents()
            c.year = calendar.component(.year, from: now)
            c.month = Int(group(m, 1, ns)); c.day = Int(group(m, 2, ns))
            c.hour = Int(group(m, 3, ns)) ?? 12; c.minute = Int(group(m, 4, ns)) ?? 0
            if valid(c), var d = calendar.date(from: c) {
                if d > latest, let prev = calendar.date(byAdding: .year, value: -1, to: d) { d = prev }
                return d
            }
        }
        if let m = relativePattern.firstMatch(in: text, range: range) {
            let offset: Int = ["今天": 0, "昨天": -1, "前天": -2][group(m, 1, ns)] ?? 0
            if let day = calendar.date(byAdding: .day, value: offset, to: now),
               let h = Int(group(m, 2, ns)), let mi = Int(group(m, 3, ns)), h < 24, mi < 60 {
                return calendar.date(bySettingHour: h, minute: mi, second: 0, of: day)
            }
        }
        return nil
    }

    private static func valid(_ c: DateComponents) -> Bool {
        guard let mo = c.month, let d = c.day else { return false }
        return (1...12).contains(mo) && (1...31).contains(d) && (0...23).contains(c.hour ?? 0) && (0...59).contains(c.minute ?? 0)
    }

    // MARK: - 收入判断

    static let incomeKeywords = ["收款成功", "已收款", "收款到账", "到账成功", "已到账", "退款成功", "已退款", "退款到账",
                                 "收到转账", "已收钱", "转入成功", "已存入零钱", "红包已存入", "工资", "代发", "入账"]

    // MARK: - 工具

    private static func group(_ m: NSTextCheckingResult, _ i: Int, _ ns: NSString) -> String {
        guard i < m.numberOfRanges else { return "" }
        let r = m.range(at: i)
        guard r.location != NSNotFound else { return "" }
        return ns.substring(with: r)
    }

    private static func replace(_ pattern: String, in s: String, with template: String) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length), withTemplate: template)
    }
}

/// 根据关键词猜测分类（名称需与默认分类一致；找不到时由调用方回退到「其他」）
enum CategoryGuesser {
    static let expenseRules: [(String, [String])] = [
        ("生活缴费", ["电费", "水费", "燃气", "煤气", "国家电网", "供电", "自来水", "物业", "缴费", "宽带", "暖气"]),
        ("娱乐", ["电影", "影城", "影院", "猫眼", "淘票票", "游戏", "Steam", "腾讯视频", "爱奇艺", "优酷", "网易云", "QQ音乐",
                "哔哩哔哩", "bilibili", "B站", "KTV", "网吧", "剧本杀", "演出", "大麦", "健身"]),
        ("通讯", ["话费", "中国移动", "中国联通", "中国电信", "流量", "手机充值"]),
        ("交通", ["滴滴", "打车", "快车", "地铁", "公交", "出行", "高德", "加油", "中石化", "中石油", "停车", "高速", "ETC",
                "12306", "铁路", "哈啰", "单车", "曹操", "T3", "花小猪", "如祺", "享道", "充电"]),
        ("旅行", ["携程", "飞猪", "去哪儿", "酒店", "机票", "航空", "民宿", "景区", "门票", "同程", "途牛"]),
        ("居住", ["房租", "租金", "自如", "贝壳", "链家", "家政", "保洁"]),
        ("医疗", ["医院", "药房", "药店", "诊所", "医保", "挂号", "体检", "口腔", "牙科"]),
        ("教育", ["学费", "培训", "课程", "书店", "教育", "考试", "知识", "得到", "网课"]),
        ("餐饮", ["美团外卖", "饿了么", "外卖", "餐", "饭", "咖啡", "星巴克", "瑞幸", "肯德基", "KFC", "麦当劳", "奶茶", "喜茶",
                "蜜雪", "茶", "食堂", "烧烤", "火锅", "小吃", "饮品", "烘焙", "面包", "必胜客", "汉堡", "塔斯汀", "面馆",
                "料理", "酒楼", "饺子", "麻辣烫", "早点", "包子", "Coffee", "coffee", "库迪", "美团"]),
        ("购物", ["淘宝", "天猫", "京东", "拼多多", "超市", "便利店", "商城", "全家", "罗森", "7-11", "7-Eleven", "盒马",
                "沃尔玛", "永辉", "唯品会", "抖音", "优衣库", "屈臣氏", "名创", "山姆", "Costco", "苹果", "Apple", "小米",
                "华为", "商店", "百货", "购物"]),
        ("人情", ["发红包", "礼金", "份子", "礼物", "鲜花", "花店"]),
    ]

    static let incomeRules: [(String, [String])] = [
        ("工资", ["工资", "薪资", "薪金", "代发"]),
        ("奖金", ["奖金", "绩效", "年终", "奖励"]),
        ("理财", ["收益", "利息", "理财", "基金", "分红", "余额宝"]),
        ("红包", ["红包"]),
        ("退款", ["退款", "退货", "退回"]),
    ]

    static func guess(text: String, isIncome: Bool) -> String? {
        let rules = isIncome ? incomeRules : expenseRules
        for (name, keywords) in rules where keywords.contains(where: { text.localizedCaseInsensitiveContains($0) }) {
            return name
        }
        return nil
    }
}
