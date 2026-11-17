# Monitor Switcher

Перемикає спільні монітори між **Mac** і **ПК з Windows** разом з клавіатурою та мишею.

- Клавіатура/миша перейшли на ПК **і** ви почали працювати на ПК → монітори йдуть на ПК.
- Клавіатура **або** миша підключилась до Mac → монітори одразу повертаються на Mac.
- Клавіатура, що просто заснула, нічого не перемикає: про те, що ви сіли за ПК, повідомляє сама програма на ПК.

Складається з двох програм, які працюють у парі через домашню мережу:

| | Mac | Windows |
|---|---|---|
| Де живе | Рядок меню (іконка моніторів) + вікно | Трей + вікно |
| Автозапуск | Об'єкти входу macOS | Реєстр `HKCU\…\Run` |
| Що робить | Стежить за Bluetooth-клавіатурою/мишею, вирішує, кому віддати монітори, перемикає по DDC/CI ті, до яких має доступ | Повідомляє Mac про дії на ПК, перемикає по DDC/CI монітори через кабель ПК |

## Як перемикаються монітори

Для кожного монітора обирається спосіб (Mac → «Монітори»):

- **DDC з Mac** — Mac напряму надсилає монітору команду VCP `0x60` (Input Source).
- **DDC через ПК** — Mac просить програму на ПК надіслати ту саму команду через кабель ПК. Для моніторів, підключених до Mac через перехідники USB‑C → HDMI, які не пропускають DDC.
- **Вимкнути сигнал** — Mac вимикає свій вихід на монітор, і той сам шукає активне джерело (потрібен Auto Source Switch у меню монітора). Запасний варіант: на Samsung G50A / LF24T450F працював ненадійно.
- **Не чіпати**.

Поточна конфігурація, перевірена на живому залізі:

| Монітор | Mac | ПК | Спосіб |
|---|---|---|---|
| ASUS XG259QN | HDMI 1 (`17`) через перехідник USB‑C | DisplayPort (`15`) | DDC через ПК |
| Samsung Odyssey G50A | HDMI (`5`) через HDMI‑порт Mac mini | DisplayPort (`15`) | DDC з Mac |
| Samsung LF24T450F (вертикальний) | HDMI 2 (`6`) через перехідник USB‑C | HDMI 1 (`5`) | DDC через ПК |

Samsung використовує власні коди входів, і вони різні в різних моделях. Samsung також показує різний PnP‑ідентифікатор на кожному вході (`SAM7095` на Mac, `SAM7094` на ПК), тому Mac зіставляє монітори ще й за назвою.

## Збирання

Потрібні Xcode Command Line Tools і .NET SDK (`brew install dotnet`) — Windows-програма збирається прямо на Mac.

```bash
scripts/build.sh            # build/Monitor Switcher.app і build/MonitorSwitcher.exe
scripts/build.sh --install  # + встановити в /Applications і запустити
```

Windows-програма — .NET Framework 4.8 (є в кожній Windows 10/11), один файл `MonitorSwitcher.exe` ~230 КБ. Вона вбудована в Mac-застосунок: відкрийте на ПК у браузері `http://<IP Mac>:47801` і завантажте її звідти. Під час першого запуску програма копіює себе в `%LOCALAPPDATA%\Programs\MonitorSwitcher`, додає ярлик у меню «Пуск» і автозапуск.

## Підключення ПК

1. Запустіть Monitor Switcher на ПК (дозвольте доступ у брандмауері).
2. На Mac: «ПК» → «Знайти ПК» → «Підключити».
3. На ПК натисніть «Дозволити».

## Мережа

| Порт | Хто слухає | Навіщо |
|---|---|---|
| TCP 47800 | ПК | `/status`, `/input`, `/mode`, `/log`… — команди від Mac (з ключем) |
| UDP 47800 | ПК | Відповідь на пошук `MSW-DISCOVER` |
| TCP 47801 | Mac | `/pc-input`, `/switch`, `/status` — від ПК (з ключем); `/` і `/download` — завантаження `.exe` |

Ключ створюється під час підключення, після підтвердження на ПК.

## Командний рядок і швидкі команди

```bash
"/Applications/Monitor Switcher.app/Contents/MacOS/MonitorSwitcher" --probe    # що бачить застосунок
"/Applications/Monitor Switcher.app/Contents/MacOS/MonitorSwitcher" --restore  # аварійно повернути все на Mac
open -g monitorswitcher://pc        # або mac, toggle, restore, auto-on, auto-off
```

Журнали: `~/Library/Logs/MonitorSwitcher.log` (Mac), `%LOCALAPPDATA%\MonitorSwitcher\log.txt` (ПК). Налаштування Mac: `~/Library/Application Support/MonitorSwitcher/config.json`.

## Як це влаштовано

- `Sources/MonitorSwitcher/Core` — DDC/CI через приватні `IOAVService` API Apple Silicon, вимкнення виходу (`CGSConfigureDisplayEnabled`), стеження за HID-пристроями через IOKit (без дозволу Input Monitoring), мережа.
- `Sources/MonitorSwitcher/Model` — налаштування й логіка перемикання.
- `Sources/MonitorSwitcher/UI` — SwiftUI-інтерфейс.
- `windows/MonitorSwitcher.Win` — програма для Windows (WPF + трей, DDC через `dxva2.dll`).
