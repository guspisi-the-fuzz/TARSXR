import Foundation

@main struct Checks {
    static func main() {
        for input in ["alô 1234", "testando 1.234", "Testando 1234", "teste: 1 2 3 4", "testando 1, 2, 3, 4"] {
            assert(AudioTestPronunciation.spokenText(input, language: "pt-BR") == "Testando. Um, dois, três, quatro.", input)
        }
        assert(AudioTestPronunciation.spokenText("testing 1,234", language: "en-US") == "Testing. One, two, three, four.")
        for input in ["custou 1.234 reais", "medida 1.234 mm", "testando valor 1.234", "1.234", "testando 12.34 metros", "senha 1234", "testando 1.235"] {
            assert(AudioTestPronunciation.spokenText(input, language: "pt-BR") == input, input)
        }
        print("13 pronunciation checks PASS")
    }
}
