"""`python -m backend` -- convenience launcher."""
import os

import uvicorn

if __name__ == "__main__":
    uvicorn.run(
        "backend.main:app",
        host=os.environ.get("TRACE_HOST", "0.0.0.0"),
        port=int(os.environ.get("TRACE_PORT", "8000")),
        reload=os.environ.get("TRACE_RELOAD", "0") in ("1", "true", "True"),
    )
