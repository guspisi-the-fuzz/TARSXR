import Foundation

@main struct Checks {
    static func main() {
        var checks = 0
        for input in ["alô 1234", "testando 1.234", "Testando 1234", "teste: 1 2 3 4", "testando 1, 2, 3, 4", "1.234"] {
            assert(AudioTestPronunciation.spokenText(input, language: "pt-BR") == "Testando. Um, dois, três, quatro.", input)
            checks += 1
        }
        for input in ["123.123", "123123", "1 2 3 1 2 3", "testando 123.123", "teste: 1, 2, 3, 1, 2, 3"] {
            assert(AudioTestPronunciation.spokenText(input, language: "pt-BR") == "Testando. Um, dois, três, um, dois, três.", input)
            checks += 1
        }
        assert(AudioTestPronunciation.spokenText("testing 123.123", language: "en-US") == "Testing. One, two, three, one, two, three.")
        checks += 1
        for input in ["custou 1.234 reais", "medida 1.234 mm", "testando valor 1.234", "testando 12.34 metros", "senha 1234", "123 mil 123", "R$ 123.123", "-123", "1", String(repeating: "1", count: 33)] {
            assert(AudioTestPronunciation.spokenText(input, language: "pt-BR") == input, input)
            checks += 1
        }
        print("\(checks) pronunciation checks PASS")
    }
}
