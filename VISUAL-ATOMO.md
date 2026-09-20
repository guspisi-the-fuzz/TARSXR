# HUD atômico — 20/09/2026

O componente CognitiveDisplay ganhou três órbitas multicoloridas, elétrons luminosos e núcleo pulsante. O EngineeringPanel permanece intacto e verde. Estados recebidos pelo model definem a energia visual; não há áudio simulado nem leitura de amplitude do microfone. IDLE continua o estado esperado no baseline atual.

Canvas atualizado em até 30 fps; timeline pausa fora da cena ativa e respeita Reduzir Movimento. Desempenho e consumo no iPhone XR físico ainda dependem do Gate 7. Nenhum gate de áudio/IA foi declarado PASS por esta mudança visual.

Validação: build Debug no iPhone 18 Pro Simulator (iOS 27.0): BUILD SUCCEEDED. Aplicativo instalado e iniciado; screenshot confirma átomo, engenharia verde, AUTONOMY NORMAL, CORE ONLINE, ESP32 CONNECTED, SAFETY CLEAR. Regressão Core: 63 passed in 0.86s.

Checkpoint anterior: 47169e0. Reversão do visual: restaurar MyApp/TarsHUDView.swift desse commit, reconstruir e testar. Git apenas local; autoria técnica Codex <codex@localhost>, sem alterar configuração global e sem publicação remota.
