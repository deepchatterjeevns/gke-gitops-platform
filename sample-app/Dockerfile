FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app.py .
# v1 = good. CI builds v2 (good) and evidence builds v2-bad (FAULT baked in).
ARG APP_VERSION=v1
ENV APP_VERSION=${APP_VERSION}
# FAULT: 0 = normal (v1/v2). 100 = all requests 500 (v2-bad for SLO rollback test).
ARG FAULT=0
ENV FAULT_PERCENT=${FAULT}
USER 65532:65532
EXPOSE 8080
CMD ["python", "app.py"]
