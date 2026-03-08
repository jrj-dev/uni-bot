FROM python:3.12-alpine

WORKDIR /app
COPY skills/unifi-event-poller/scripts/unifi_event_poller.py /app/unifi_event_poller.py

ENV PYTHONDONTWRITEBYTECODE=1
ENV PYTHONUNBUFFERED=1
ENV UNIFI_EVENT_PATH=/proxy/network/v2/api/site/default/event
ENV UNIFI_EVENT_LIMIT=50
ENV UNIFI_POLL_INTERVAL_SECONDS=30
ENV UNIFI_EVENT_TIMEOUT_SECONDS=20
ENV UNIFI_EVENT_LOKI_JOB=unifi_network_events
ENV UNIFI_INSECURE=true
ENV LOKI_INSECURE=false

CMD ["python3", "/app/unifi_event_poller.py"]
