# Evidência de validação — etapa 1

Ambiente: Linux, Swift 6.0.3, compilação em modo Swift 5. Sem Xcode, UIKit, AVFoundation ou microfone do XR disponíveis para execução.

- A suíte portátil completa passou em `/tmp/tars-xr-validation.9fBiKN`. Incluiu 218 checks de memória persistente, 384 de relações, 228 de intenção de fala, 307 de lógica, 167 de política de voz, 1022 de relógio e as verificações de qualidade/admissão visual, reconexão, música e transporte remoto. São contagens de checks, não de casos independentes.
- A versão final dos checks novos de conversa passou com **56 checks**, cobrindo origem, prazo, correção/exclusão, câmera→conversa, ferramenta→conversa, ambiguidade de referente salvo, erros de armazenamento, chamada duplicada, cancelamento e preparação ordenada de áudio.
- O teste do parser real, extraído do arquivo de produção com substituição somente de `AVCaptureDevice.Position`, passou. Confere fotografia/selfie/procura de Mel, texto/código, perguntas históricas e fronteiras com perguntas não visuais.
- Todos os arquivos Swift de produção e testes passaram pela análise sintática (`swiftc -frontend -parse`). Isso **não equivale a compilar/typecheckar o SDK iOS**.
- `git diff --check` e análise sintática dos scripts Bash passaram.
- Novos testes nativos por URLProtocol e testes do ciclo real dos delegates com áudio silencioso estão incluídos para o Mac/Simulator; não foram executados aqui.

## Ocorrência durante repetição da suíte

Uma repetição posterior terminou com SIGILL no teste de memória persistente, sem mensagem de precondição e com falhas do backtrace ao ler `/proc/.../stat`. Houve também uma ocorrência semelhante na execução dos novos checks. Não se determinou a causa. Não foi removida nenhuma asserção nem convertido erro em aprovação.

O teste de memória foi então compilado separadamente com impressão temporária de cada asserção: as 218 verificações passaram. A instrumentação permaneceu fora do repositório. Os novos checks também passaram novamente. Portanto há passes reproduzidos, mas a ocorrência deve permanecer registrada; a aprovação do Mac/Simulator é obrigatória antes do build físico. O script normal continua parando no primeiro erro.

## Não executado

- Builds Debug/Release com SDK Apple.
- Instalação e ciclo de execução no iOS Simulator.
- Chamadas pagas à IA, avaliação semântica de respostas reais ou medição de latência da rede.
- Reconhecimento de fala, eco/barge-in acústico, Bluetooth/JBL, foco/OCR real, bateria ou temperatura no XR.

O comando `bash scripts/validate-conversation-simulator.sh` foi preparado para executar as verificações de software Apple sem instalar no XR. A aceitação física detalhada está em `ETAPA1_CONVERSA.md`.

## Primeira tentativa no Mac

O build Debug para Simulator rejeitou `ConversationContext.append` por acesso sobreposto: `turns.removeAll` modificava a estrutura enquanto a closure lia a propriedade `lifetime`. A correção copia o limite para uma constante antes da operação. Os 56 checks portáteis passaram após a correção. O script de build agora imprime os erros encontrados no log completo; o novo build Apple ainda precisa ser executado.

## Segunda tentativa no Mac

O usuário forneceu o log completo: Debug antes/depois dos testes e Release para iOS passaram; passaram também os testes nativos/HTTP e os 56 checks novos. O ciclo simulado então parou em “Wake must acknowledge and await question”. A inspeção confirmou que a saudação é assíncrona, mas o teste lia o estado imediatamente, e que a fixture não separava o callback de saudação das perguntas gerais. O teste agora aguarda SPEAKING e fornece wakeRespond próprio. O despertar real agora marca THINKING, mantém a tarefa de saudação cancelável e não envia uma saudação implícita para o callback de perguntas comuns. A opção --cycle-only permite recompilar Debug e repetir somente o ciclo; não representa nova aprovação de Release.

## Terceira tentativa no Mac — ciclo aprovado

Em 16/10/2026, o usuário executou `TARSXR_ETAPA1_CORRIGIR_WAKE.command` e forneceu o resultado PASS para Debug + ciclo simulado do app, no iPhone 18 Pro Simulator. O ciclo incluiu permissões e normalização de câmera simulada, cancelamento, histórico visual PT/EN, áudio silencioso com delegates, despertar, follow-ups, callbacks atrasados, bloqueio de falha permanente e recuperação. A produção testada corresponde ao commit de código `4f3e526`.

A suíte completa e os builds Debug/Release haviam passado na segunda tentativa. Na terceira foi repetido somente Debug + ciclo, conforme indicado explicitamente pelo script. Portanto **não há evidência de novo build Release após a correção do despertar**. Nenhum desses resultados comprova reconhecimento acústico, eco, JBL, latência de rede ou bateria/temperatura no XR físico. A etapa 1 segue pendente de aceitação física e publicação no repositório do usuário.
