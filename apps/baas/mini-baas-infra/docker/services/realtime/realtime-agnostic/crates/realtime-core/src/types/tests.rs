use super::*;
use bytes::Bytes;
use std::collections::HashMap;

#[test]
fn event_id_generation() {
    let id1 = EventId::new();
    let id2 = EventId::new();
    assert_ne!(id1, id2);
}

#[test]
fn topic_path_parts() {
    let topic = TopicPath::new("orders/created");
    assert_eq!(topic.namespace(), "orders");
    assert_eq!(topic.event_type_part(), "created");
}

#[test]
fn topic_pattern_exact() {
    let pattern = TopicPattern::Exact(TopicPath::new("orders/created"));
    assert!(pattern.matches(&TopicPath::new("orders/created")));
    assert!(!pattern.matches(&TopicPath::new("orders/updated")));
}

#[test]
fn topic_pattern_prefix() {
    let pattern = TopicPattern::Prefix(smol_str::SmolStr::new("orders/"));
    assert!(pattern.matches(&TopicPath::new("orders/created")));
    assert!(pattern.matches(&TopicPath::new("orders/deleted")));
    assert!(!pattern.matches(&TopicPath::new("users/created")));
}

#[test]
fn topic_pattern_glob() {
    let p1 = TopicPattern::Glob(smol_str::SmolStr::new("orders/*"));
    assert!(p1.matches(&TopicPath::new("orders/created")));
    assert!(!p1.matches(&TopicPath::new("users/anything")));

    let p2 = TopicPattern::Glob(smol_str::SmolStr::new("*/created"));
    assert!(p2.matches(&TopicPath::new("orders/created")));
    assert!(!p2.matches(&TopicPath::new("users/deleted")));
}

#[test]
fn topic_pattern_parse() {
    assert!(matches!(
        TopicPattern::parse("orders/created"),
        TopicPattern::Exact(_)
    ));
    assert!(matches!(
        TopicPattern::parse("orders/"),
        TopicPattern::Prefix(_)
    ));
    assert!(matches!(
        TopicPattern::parse("orders/*"),
        TopicPattern::Glob(_)
    ));
}

#[test]
fn event_envelope_creation() {
    let payload = Bytes::from(r#"{"key":"value"}"#);
    let event = EventEnvelope::new(TopicPath::new("test/event"), "created", payload);
    assert_eq!(event.topic, TopicPath::new("test/event"));
    assert!(!event.is_payload_too_large());
}

#[test]
fn payload_too_large() {
    let payload = Bytes::from(vec![0u8; 70_000]);
    let event = EventEnvelope::new(TopicPath::new("test"), "test", payload);
    assert!(event.is_payload_too_large());
}

#[test]
fn auth_claims_subscribe() {
    let claims = AuthClaims {
        sub: "user1".to_string(),
        namespaces: vec!["orders".to_string(), "users".to_string()],
        can_publish: false,
        can_subscribe: true,
        metadata: HashMap::new(),
    };
    let allowed = TopicPattern::Exact(TopicPath::new("orders/created"));
    let denied = TopicPattern::Exact(TopicPath::new("admin/settings"));
    assert!(claims.can_subscribe_to(&allowed));
    assert!(!claims.can_subscribe_to(&denied));
}
