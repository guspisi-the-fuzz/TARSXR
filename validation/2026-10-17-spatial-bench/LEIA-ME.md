# Bloco 4 — primeiro pacote de bancada

Este pacote implementa um primeiro ciclo de software de 4A, 4B e 4C, e a auditoria preparatória de 4D. Não conclui navegação física. O histórico identificou o repositório privado guspisi-the-fuzz/tars-firmware, main, com clone local em ~/Documents/TARS/Software/TARS-RC3/tars-firmware. Conteúdo posteriormente recebido por ZIP e auditado em FIRMWARE_AUDIT.md; não depende mais do navegador. O patch separado de firmware corrige apenas a emissão JSON dos quatro encoders e seu teste. Não altera GPIO, motores, calibração ou segurança.

## Entregas e limites

- **4A:** modo ARKit explícito, pose da câmera, trilha relativa, estados/idade, bloqueio térmico/baixo consumo, exclusão de câmera e diagnóstico compartilhável. A câmera continua montada em um pescoço: pose do chassi permanece indisponível. Sem imagem ao vivo ou detector de caixas nesta primeira tela.
- **4B:** marcar pontos nomeados, salvar mapa ARKit e grafo localmente, carregar e exigir relocalização com âncora da referência antes de usar coordenadas. “Ponto próximo” significa proximidade geométrica a um ponto cadastrado, não classificação visual automática do cômodo/pessoa/gata. Reconhecimento semântico e detecção de obstáculos ainda não implementados.
- **4C:** conexões declaradas pelo operador e menor percurso geométrico no grafo. Exige rastreamento recente e proximidade até 0,75 m do ponto de partida. Proposta expira em 1 segundo e some ao perder tracking. Não representa espaço livre ou rota executável. Curvas exigem pontos intermediários.
- **4D preparatório:** composição câmera/pescoço/corpo com ângulos medidos e relógios sincronizados; relatório sempre sem autoridade de atuação. Inventário de fontes locais com script de leitura, sem rede/serial/GPIO. Protocolo Body V0 auditado, com importação histórica de status/capabilities/encoders; ligação ao vivo e bancada física continuam pendentes; não há integração de movimento nova.

## Uso

1. Pare “visão local”; não é ativada nem desligada implicitamente pela bancada espacial.
2. Abra “Bancada espacial” e “Novo mapa”. Mova manualmente o XR por um local iluminado, com detalhes visuais. A trilha representa somente o aparelho.
3. Cadastre pontos da câmera ao longo do caminho. Declare conexões entre pontos cuja ligação você conhece.
4. Salve quando o ARKit tiver mapa suficiente. Existe um único arquivo espacial, substituído ao salvar. É independente da memória pessoal.
5. Retorne a um ponto cadastrado e simule o percurso até outro. Linha laranja é proposta simulada entre pontos, sem verificação de obstáculos.
6. Pare; carregue o mapa e volte a observar a área mapeada para relocalizar. A origem precisa corresponder ao mapa antes de habilitar pontos/rota.
7. Fechar o painel ou sair do app para a sessão. Fotografias/descrições existentes exigem o modo espacial parado. Não há duas sessões simultâneas ou reinício automático.

ARKit pode consumir mais que a visão econômica. Só a publicação de estado/trilha é limitada a 4 Hz; ARKit executa na cadência de vídeo suportada selecionada. Detecção pesada, profundidade inferida e chamadas pagas não foram adicionadas.

## Validação Mac

`bash scripts/validate-spatial-bench.sh`

Inclui os testes novos, todas as regressões existentes, builds Debug/Release e ciclo simulado do app. O ciclo também exercita os métodos reais de estado da bancada com eventos simulados, sem iniciar ARSession. Build com SDK iOS depende do Mac; não foi executado no ambiente Linux.

## Auditoria de fontes do corpo no Mac

Exemplo, substituindo o caminho se necessário:

```bash
python3 scripts/audit-spatial-body.py "/Users/guzzfuzz/Documents/TARS/Software/TARS-RC3" --output /tmp/TARS-corpo-auditoria.json
```

O relatório contém caminhos e números de linhas de evidências, sem copiar código nem credenciais. Correspondência de palavras não comprova implementação. Revisar origem medida/estimada de pan/tilt, timestamps, eixos/sinais, calibração, odometria, confirmações e intertravamentos antes de qualquer proposta de integração.

## Próximo fechamento real

Primeiro obter build Mac e aceitar percepção/relocalização no XR. Depois auditar fontes do ESP32 e validar fisicamente a interface existente. Não tratar este pacote como conclusão de 4D ou autorização de dirigir o robô.


## Rodas independentes

Também há um painel de cálculo geométrico das quatro rodas direcionais: informe entre-eixos, bitola e limites por roda sem presumir números físicos. O cálculo produz quatro ângulos relativos e quatro velocidades lineares, com redução comum para preservar a geometria e recusa de intenção inviável. Não é conectado ao percurso/visão, não configura servos, não converte velocidade em PWM e não considera a dinâmica física. Pescoço tem dois canais próprios e não entra na direção das rodas.

## Body V0

O painel importa arquivos pequenos contendo SOMENTE linhas JSON completas de status, capabilities e encoders Body V0. ACK/diagnostics e outros tipos não são aceitos por esse importador. São registros históricos: nem uptime nem flags true estabelecem estado ao vivo ou autoridade de movimento. Fonte e achados completos em FIRMWARE_AUDIT.md. A fixture de encoders truncada no host é negativa e deve ser recusada.

O validador Mac também tenta testes host/virtuais e build do firmware local; passos ausentes são marcados NOT RUN e não contam como aprovação. O instalador aplica também o patch mínimo de emissão de encoders ao clone local do firmware, com preflight e backup próprios; não faz flash.

Build corrigido do firmware passou no ambiente de desenvolvimento: RAM 23.016 bytes, flash 310.537 bytes. Sem flash. O validador usa telemetria PlatformIO desativada por variável suportada, sem modificar preferências globais.
