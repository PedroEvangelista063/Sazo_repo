import sys
from pathlib import Path

PROJETO_RAIZ = Path(__file__).resolve().parents[2]
if str(PROJETO_RAIZ) not in sys.path:
    sys.path.insert(0, str(PROJETO_RAIZ))
