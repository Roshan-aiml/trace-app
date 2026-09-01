import os, tempfile
import streamlit as st
import pandas as pd

from trace_pipeline import run_pipeline, generate_pdf_report, log_telemetry, RULES_CONFIG, HISTORY_CSV

st.set_page_config(page_title="TRACE -- Legal Metrology Compliance", page_icon="\U0001F50D", layout="wide")

with st.sidebar:
    st.title("TRACE")
    st.caption("PaddleOCR + qwen/qwen3.6-27b")
    key_input = st.text_input("Groq API key (optional)", type="password", value=os.environ.get("GROQ_API_KEY", ""))
    if key_input:
        os.environ["GROQ_API_KEY"] = key_input
    use_llm_correction = st.checkbox("LLM text correction", value=bool(os.environ.get("GROQ_API_KEY")))
    use_llm_agent = st.checkbox("VLM escalation for weak fields", value=bool(os.environ.get("GROQ_API_KEY")))

tab_scan, tab_dash, tab_hist = st.tabs(["Scan & Inspect", "Dashboard", "History"])

VERDICT_STYLE = {"PASS": "success", "REVIEW": "warning", "HOLD": "error", "REJECTED": "error"}

with tab_scan:
    mode = st.radio("Capture mode", ["Upload", "Live scan"], horizontal=True, key="mode")
    capture_mode = "upload" if mode == "Upload" else "live_scan"

    col_in, col_out = st.columns([1, 1.4])
    with col_in:
        img_file = st.file_uploader("Upload a label photo", type=["jpg", "jpeg", "png"]) if mode == "Upload" \
            else st.camera_input("Capture label")
        product_name = st.text_input("Product name (optional, for the log)")
        run_btn = st.button("Run inspection", type="primary", disabled=img_file is None)

    with col_out:
        if run_btn and img_file is not None:
            with tempfile.NamedTemporaryFile(suffix=".jpg", delete=False) as tmp:
                tmp.write(img_file.getvalue())
                tmp_path = tmp.name
            with st.spinner("Running quality gate, OCR, and field checks..."):
                result = run_pipeline(tmp_path, use_llm_correction=use_llm_correction,
                                       use_llm_agent=use_llm_agent, capture_mode=capture_mode)
            st.session_state.update(last_result=result, last_image_path=tmp_path,
                                     last_product_name=product_name, quality_override_used=False)
            st.session_state.pop("last_pdf_bytes", None)

        result = st.session_state.get("last_result")
        tmp_path = st.session_state.get("last_image_path")

        if not result:
            st.info("Upload or capture a label photo, then click Run inspection.")
        elif not result["quality_passed"] and not result.get("quality_overridden"):
            qm = result["quality_metrics"]
            c1, c2 = st.columns(2)
            c1.metric("Clarity", f"{qm.get('clarity_pct', 0)}%")
            c2.metric("Exposure", f"{qm.get('exposure_pct', 0)}%", qm.get("exposure_label", ""),
                      delta_color="off")
            for r in result["quality_reasons"]:
                st.write(f"- {r}")
            if mode == "Upload":
                st.error("Image rejected. Please retake and re-upload a clearer photo.")
            else:
                st.warning("Image quality is poor. Retake, or approve manually if you can confirm the product yourself.")
                bc1, bc2 = st.columns(2)
                with bc1:
                    if st.button("Rescan"):
                        st.session_state.pop("last_result", None)
                        st.rerun()
                with bc2:
                    if st.button("Approve manually"):
                        with st.spinner("Running with quality override..."):
                            result2 = run_pipeline(tmp_path, use_llm_correction=use_llm_correction,
                                                    use_llm_agent=use_llm_agent, capture_mode="live_scan",
                                                    quality_override=True)
                        log_telemetry(result2, product_name=st.session_state.get("last_product_name", ""),
                                      human_decision="Manual approve (quality override)")
                        st.session_state["last_result"] = result2
                        st.rerun()
        else:
            qm = result["quality_metrics"]
            style = VERDICT_STYLE.get(result["verdict"], "info")
            getattr(st, style)(f"**{result['verdict']}**")
            mc1, mc2, mc3 = st.columns(3)
            mc1.metric("Clarity", f"{qm.get('clarity_pct', 0)}%")
            mc2.metric("Exposure", f"{qm.get('exposure_pct', 0)}%", qm.get("exposure_label", ""),
                       delta_color="off")
            mc3.metric("Resolution", qm.get("width") and f"{qm['width']}x{qm['height']}" or "--")
            if result.get("quality_overridden"):
                st.caption("Quality gate was manually overridden by the employee.")
            st.caption(f"OCR source: `{result.get('ocr_source')}`")
            if result.get("font_warnings"):
                for w in result["font_warnings"]:
                    st.warning(w)
            with st.expander("Show raw OCR text (debug)"):
                st.text(result.get("raw_text") or "(empty)")

            rows = [{"Declaration": RULES_CONFIG[k]["label"], "Value": f.get("value") or "--",
                     "Confidence": f.get("confidence", 0), "Status": f.get("level", "?")}
                    for k, f in result["fields"].items()]
            st.dataframe(pd.DataFrame(rows), use_container_width=True, hide_index=True)

            if result["violations"]:
                st.write("**Violations**")
                for v in result["violations"]:
                    st.write(f"- {v}")

            if result.get("review_notes"):
                st.write("**Needs manual check**")
                for n in result["review_notes"]:
                    st.write(f"- {n}")

            if mode == "Live scan":
                st.write("**Human-in-the-loop decision**")
                decision = st.radio("Final action", ["Approve", "Rescan", "Hold", "Override"], horizontal=True, key="decision")
            else:
                decision = ""

            if st.button("Save to history + generate report"):
                pdf_path = generate_pdf_report(result, tmp_path)
                log_telemetry(result, product_name=st.session_state.get("last_product_name", ""),
                              human_decision=decision)
                with open(pdf_path, "rb") as fh:
                    st.session_state["last_pdf_bytes"] = fh.read()
                st.success("Logged to inspection history.")

            if st.session_state.get("last_pdf_bytes"):
                st.download_button("Download PDF report", st.session_state["last_pdf_bytes"],
                                   file_name="trace_report.pdf", mime="application/pdf")

with tab_dash:
    st.subheader("Compliance dashboard")
    if os.path.exists(HISTORY_CSV):
        df = pd.read_csv(HISTORY_CSV)
        c1, c2, c3, c4 = st.columns(4)
        c1.metric("Total scanned", len(df))
        c2.metric("Pass rate", f"{(df.verdict == 'PASS').mean()*100:.0f}%" if len(df) else "--")
        c3.metric("Review", int((df.verdict == "REVIEW").sum()))
        c4.metric("Hold", int((df.verdict == "HOLD").sum()))
        st.bar_chart(df["verdict"].value_counts())
    else:
        st.info("No inspections logged yet.")

with tab_hist:
    st.subheader("Inspection history")
    if os.path.exists(HISTORY_CSV):
        df = pd.read_csv(HISTORY_CSV)
        search = st.text_input("Search by product name")
        if search:
            df = df[df["product_name"].astype(str).str.contains(search, case=False, na=False)]
        st.dataframe(df.sort_values("timestamp", ascending=False), use_container_width=True, hide_index=True)
    else:
        st.info("No history yet.")
