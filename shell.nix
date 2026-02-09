{ pkgs ? import <nixpkgs> {} }:

pkgs.mkShell {
  name = "sre-consilium-engine";

  buildInputs = with pkgs; [
    python312
    python312Packages.pip
    python312Packages.virtualenv
    stdenv.cc.cc.lib
    zlib
    glib
  ];

  LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [
    pkgs.stdenv.cc.cc.lib
    pkgs.zlib
    pkgs.glib
  ];

  shellHook = ''
    # Создаем venv в папке ДВИЖКА
    if [ ! -d ".venv" ]; then
      echo "📦 [Engine] Creating virtual environment..."
      python3 -m venv .venv
    fi

    source .venv/bin/activate

    # АВТО-ЛЕЧЕНИЕ: Проверяем наличие requirements.txt и ставим пакеты
    if [ -f requirements.txt ]; then
        # Тихая установка, но с принудительным ignore-installed для решения конфликтов
        pip install -q --disable-pip-version-check --ignore-installed -r requirements.txt
    else
        echo "⚠️ WARNING: requirements.txt not found in Engine dir!"
    fi
  '';
}