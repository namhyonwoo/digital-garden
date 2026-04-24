---
title: 해외배송 통합 설계 — 어드민 메뉴 구성 및 배송 플로우
permalink: /overseas-shipping-design
tags:
  - backend
  - commerce
  - architecture
  - overseas-shipping
  - admin
aliases:
  - shipping design
  - 해외배송 설계
---

## 배경

현재 주문 시스템은 국내배송만 지원하며, 해외배송(일본, 대만, 싱가포르 등)을 추가해야 한다.
해외배송은 국내배송과 플로우가 다르다.

- 국내 → **배송대행지**로 발송 (국내송장)
- 배송대행지에서 **국제송장번호** 발급 후 최종 배송국으로 발송
- 즉, 송장이 2단계(국내 + 국제)로 나뉨

### 현재 상태 (이미 존재하는 것)

| 항목 | 현황 |
|------|------|
| `ShippingScope` enum | `DOMESTIC`, `OVERSEAS` — 이미 존재 |
| `ProductOrder.shippingScope` | 엔티티 필드 존재, 검색 필터 미구현 |
| `Orders.personalCustomsCode` | 개인통관고유번호 필드 존재 |
| `DeliveryHoldReason.OVERSEAS_SHIPPING` | 배송보류 사유에 해외배송 존재 |
| 검색 필터 (shippingScope) | **미구현** — QueryDSL predicate 없음 |

---

## 메뉴 구성 방안: 하이브리드 (리스트 통합 + 상세/액션 분기)

### 검토한 3가지 안

| 방안 | 설명 | 판정 |
|------|------|------|
| A. 완전 분리 | 국내/해외 메뉴를 완전히 나눔 | ❌ Controller, Service, DTO 이중화 → 유지보수 비용 높음 |
| B. 완전 통합 | 기존 메뉴에 필터만 추가 | ❌ 해외배송 플로우(대행지 도착, 국제송장) 처리가 같은 화면에서 혼란 |
| **C. 하이브리드** | **리스트 통합 + 상세/액션만 분기** | ✅ 코드 중복 없이 플로우 차이 대응 |

### 선택: 안 C — 하이브리드

```
주문관리
├── 주문 관리                      ← 통합 리스트 (shippingScope 탭 필터)
│   ├── [탭] 전체 | 국내 | 해외
│   ├── 주문 상세 (국내)           ← 기존 그대로
│   └── 주문 상세 (해외)           ← 국제배송 섹션 추가
├── 취소주문 관리                   ← 기존 유지
├── 교환관리                       ← 기존 유지
└── 반품관리                       ← 기존 유지
```

---

## 배송 플로우 비교

### 국내배송 (기존 — 변경 없음)

```
결제완료 → [발주확인] → 상품준비중 → [송장등록] → 배송중 → [배송완료] → 구매확정
  PAID       →        PREPARING     →        SHIPPING  →  DELIVERED → CONFIRMED
```

### 해외배송 (신규)

```
결제완료 → [발주확인] → 상품준비중 → [국내송장등록] → 배송중(국내→대행지)
  PAID       →        PREPARING      →            SHIPPING

→ [대행지도착처리] → 대행지도착 → [국제송장등록] → 국제배송중 → [배송완료] → 구매확정
                  ARRIVED_AT_WAREHOUSE    →    INTERNATIONAL_SHIPPING → DELIVERED → CONFIRMED
```

### ProductOrderStatus 변경

```java
// 기존 (유지)
PENDING, PAID, PREPARING, SHIPPING, ON_HOLD_DELIVERY, DELIVERED, CONFIRMED, CANCELED

// 신규 추가
ARRIVED_AT_WAREHOUSE("대행지도착"),        // 해외배송 전용: 배송대행지 도착
INTERNATIONAL_SHIPPING("국제배송중"),      // 해외배송 전용: 국제송장 등록 후
```

---

## 백엔드 변경 범위

### 1. commerce-core — 엔티티/VO 변경

#### 1-1. 신규 enum

```java
// 배송 국가
public enum ShippingCountry {
    KR("한국", null),
    JP("일본", "일본 배송대행지"),
    TW("대만", "대만 배송대행지"),
    SG("싱가포르", "싱가포르 배송대행지"),
    US("미국", "미국 배송대행지");

    private final String name;
    private final String forwardingWarehouseLabel;
}
```

#### 1-2. Orders 엔티티 — 해외 배송지 필드 추가

```java
// 기존 배송지 필드 (유지)
private String recipientName;
private String recipientPhone;
private String zipCode;
private String shippingAddressBase;
private String shippingAddressDetail;
private String deliveryMemo;
private String personalCustomsCode;

// 신규 추가
@Enumerated(EnumType.STRING)
private ShippingType shippingType;          // 국내/해외 구분

@Enumerated(EnumType.STRING)
private ShippingCountry shippingCountry;    // 배송 국가 (해외일 때)

private String shippingState;               // 주/도 (해외)
private String shippingCity;                // 시 (해외)
```

> 배송지는 기존처럼 Orders에 임베드 유지 (주문 1건 = 배송지 1건, 별도 테이블 불필요)

#### 1-3. ProductOrder 엔티티 — 국제송장 필드 추가

```java
// 기존 (유지 — 국내송장으로 사용)
private String deliveryTrackingNumber;
private String deliveryCompany;
private LocalDateTime invoiceRegisteredAt;
private LocalDateTime invoiceUpdatedAt;

// 신규 추가 — 국제배송 전용
private String internationalTrackingNumber;         // 국제송장번호
private String internationalDeliveryCompany;        // 국제배송사
private LocalDateTime internationalInvoiceRegisteredAt;
private String forwardingWarehouseCode;             // 배송대행지 코드
private LocalDateTime arrivedAtWarehouseAt;         // 대행지 도착 시각
```

#### 1-4. ProductOrderStatus — 상태 2개 추가

```java
ARRIVED_AT_WAREHOUSE("대행지도착"),
INTERNATIONAL_SHIPPING("국제배송중"),
```

#### 1-5. 신규 엔티티 — InternationalShippingPolicy

```java
@Entity
public class InternationalShippingPolicy {
    private Long id;
    private ShippingCountry country;                // 국가
    private Long shippingFee;                       // 국가별 기본 국제배송비
    private Long additionalFeePerItem;              // 추가 상품당 배송비
    private String forwardingWarehouseAddress;      // 대행지 주소
    private String forwardingWarehouseCode;         // 대행지 코드
    private String forwardingWarehouseContact;      // 대행지 연락처
    private Boolean active;                         // 활성화 여부
}
```

### 2. commerce-super-admin — 리스트 (기존 API 확장)

#### 2-1. SearchCriteria에 필터 추가

```java
// ProductOrderAdminSearch.SearchCriteria
private ShippingScope shippingScope;        // null=전체, DOMESTIC, OVERSEAS
private ShippingCountry shippingCountry;    // 해외탭에서 국가별 필터 (선택)
```

#### 2-2. QueryDSL predicate 추가

```java
// OrderAdminQueryPredicates
BooleanExpression shippingScopeEq(ShippingScope scope) {
    return scope == null ? null : productOrder.shippingScope.eq(scope);
}

BooleanExpression shippingCountryEq(ShippingCountry country) {
    return country == null ? null : orders.shippingCountry.eq(country);
}
```

#### 2-3. 리스트 응답에 필드 추가

```java
// ProductOrderAdminSearch.Result
private ShippingScope shippingScope;        // 배송구분 표시용
private ShippingCountry shippingCountry;    // 국가 표시용 (해외일 때)
```

### 3. commerce-super-admin — 상세 (기존 응답 확장)

```java
// ProductOrderAdminDetail에 추가
private InternationalShippingInfo internationalShippingInfo;

@Data
public static class InternationalShippingInfo {
    private ShippingCountry shippingCountry;            // 배송국가
    private String forwardingWarehouseAddress;          // 배송대행지 주소
    private String forwardingWarehouseCode;             // 대행지 코드
    private String internationalTrackingNumber;         // 국제송장번호
    private String internationalDeliveryCompany;        // 국제배송사
    private LocalDateTime arrivedAtWarehouseAt;         // 대행지 도착일시
    private LocalDateTime internationalShippedAt;       // 국제배송 시작일시
}
```

> `shippingScope == DOMESTIC`이면 `internationalShippingInfo`는 null → 프론트에서 해당 섹션 미노출

### 4. commerce-super-admin — 신규 API (해외배송 전용 2개)

#### 4-1. 대행지 도착 처리

```
PATCH /order/orders/product-orders/warehouse-arrival
```

```java
public static class WarehouseArrivalRequest {
    @NotEmpty
    private List<Long> productOrderIds;
}
```

동작:

- `productOrderStatus`: `SHIPPING` → `ARRIVED_AT_WAREHOUSE`
- `arrivedAtWarehouseAt` 설정

#### 4-2. 국제송장 등록

```
PATCH /order/orders/product-orders/international-shipment
```

```java
public static class InternationalShipmentRequest {
    @NotEmpty
    private List<Long> productOrderIds;
    @NotBlank
    private String internationalDeliveryCompany;
    @NotBlank
    private String internationalTrackingNumber;
}
```

동작:

- `productOrderStatus`: `ARRIVED_AT_WAREHOUSE` → `INTERNATIONAL_SHIPPING`
- `internationalTrackingNumber`, `internationalDeliveryCompany` 설정
- `internationalInvoiceRegisteredAt` 설정

### 5. 기존 API 변경 사항

| API | 변경 내용 |
|-----|----------|
| `PATCH /product-orders/shipment` | 변경 없음 — 해외주문도 1차 국내송장은 동일하게 등록 |
| `PATCH /product-orders/delivery-completion` | 해외주문은 `INTERNATIONAL_SHIPPING` → `DELIVERED` 전이 추가 |
| `POST /product-orders/bulk-shipment-update` | 엑셀에 국제송장 컬럼 추가 (선택) |
| `GET /{orders-id}` 상세조회 | 응답에 `InternationalShippingInfo` 포함 |
| `GET /product-orders` 목록조회 | 검색조건에 `shippingScope`, `shippingCountry` 추가 |

### 6. commerce-app-api — 주문 생성 확장

```java
// OrderSave.DeliveryInfo에 추가
private ShippingType shippingType;          // 국내/해외 (기본값: DOMESTIC)
private ShippingCountry shippingCountry;    // 해외일 때 국가 선택

// 해외 주소 필드
private String shippingState;               // 주/도
private String shippingCity;                // 시
```

---

## 프론트엔드 화면 구성

### 리스트 화면

```
┌──────────────────────────────────────────────────────────┐
│  주문 관리                                                 │
│                                                           │
│  [전체] [국내배송] [해외배송]          ← shippingScope 탭   │
│                                                           │
│  해외배송 탭 선택 시: [국가 선택 ▼] 필터 추가 노출            │
│                                                           │
│  ┌──────────┬────────┬───────────┬──────────┬─────────┐  │
│  │ 주문번호  │ 상품명  │ 주문상태    │ 배송구분  │ 국가    │  │
│  ├──────────┼────────┼───────────┼──────────┼─────────┤  │
│  │ 20260408 │ 반팔티  │ 배송중     │ 국내     │ -       │  │
│  │ 20260408 │ 원피스  │ 대행지도착  │ 해외     │ 일본    │  │
│  │ 20260408 │ 자켓   │ 국제배송중  │ 해외     │ 대만    │  │
│  └──────────┴────────┴───────────┴──────────┴─────────┘  │
│                                                           │
│  ※ "대행지도착", "국제배송중" 상태는 해외주문에서만 노출       │
└──────────────────────────────────────────────────────────┘
```

### 상세 화면 — 국내 주문 (기존 그대로)

```
┌──────────────────────────────────────────────┐
│  주문 상세 (#20260408-001)                     │
│                                               │
│  ■ 주문 정보                                   │
│  ■ 주문자 정보                                  │
│  ■ 배송지 정보                                  │
│    수령인: 홍길동 / 010-1234-5678              │
│    주소: 서울시 강남구 테헤란로 123              │
│                                               │
│  ■ 배송 정보                                   │
│    택배사: CJ대한통운                           │
│    송장번호: 123456789                         │
│    [배송완료 처리]                              │
│                                               │
│  ■ 결제 정보                                   │
│  ■ 타임라인                                    │
└──────────────────────────────────────────────┘
```

### 상세 화면 — 해외 주문 (국제배송 섹션 추가)

```
┌──────────────────────────────────────────────┐
│  주문 상세 (#20260408-002)         [해외배송]   │
│                                               │
│  ■ 주문 정보                                   │
│  ■ 주문자 정보                                  │
│                                               │
│  ■ 배송지 정보                ← 해외주소 형식    │
│    국가: 일본                                  │
│    수령인: 田中太郎 / +81-90-1234-5678         │
│    주소: 東京都渋谷区神宮前1-2-3               │
│    개인통관번호: P123456789012                  │
│                                               │
│  ■ 국내배송 정보 (→ 배송대행지)  ← 기존 송장 영역│
│    택배사: CJ대한통운                           │
│    송장번호: 123456789                         │
│    배송대행지: 일본 도쿄 대행지                   │
│    상태: 배송대행지 도착 (2026-04-10)            │
│                                               │
│  ■ 국제배송 정보              ← ⭐ 해외 전용    │
│    국제배송사: EMS                              │
│    국제송장번호: JP-EMS-9876543                 │
│    국제배송 시작: 2026-04-11                    │
│                                               │
│    [대행지 도착 처리] [국제송장 등록] [배송완료]   │
│                                               │
│  ■ 결제 정보                                   │
│  ■ 타임라인                                    │
│    04-08 결제완료                               │
│    04-08 발주확인                               │
│    04-09 국내송장등록 (CJ대한통운 123456789)     │
│    04-10 배송대행지 도착                         │
│    04-11 국제송장등록 (EMS JP-EMS-9876543)      │
└──────────────────────────────────────────────┘
```

---

## 상태 전이 규칙

### 국내배송 (기존 — 변경 없음)

```
PAID ──────→ PREPARING ──────→ SHIPPING ──────→ DELIVERED ──────→ CONFIRMED
       발주확인          송장등록         배송완료          구매확정

       ↕ (어느 단계에서든)
  ON_HOLD_DELIVERY (배송보류)
```

### 해외배송

```
PAID ──→ PREPARING ──→ SHIPPING ──→ ARRIVED_AT_WAREHOUSE ──→ INTERNATIONAL_SHIPPING ──→ DELIVERED ──→ CONFIRMED
   발주확인       국내송장등록     대행지도착처리             국제송장등록               배송완료      구매확정

   ↕ (PREPARING ~ SHIPPING 단계에서)
ON_HOLD_DELIVERY (배송보류)
```

### 상태별 허용 액션 (어드민)

| 현재 상태 | 국내배송 허용 액션 | 해외배송 허용 액션 |
|----------|------------------|------------------|
| PAID | 발주확인, 취소 | 발주확인, 취소 |
| PREPARING | 송장등록, 배송보류, 취소 | 국내송장등록, 배송보류, 취소 |
| SHIPPING | 배송완료 | 대행지도착처리 |
| ARRIVED_AT_WAREHOUSE | - | 국제송장등록 |
| INTERNATIONAL_SHIPPING | - | 배송완료 |
| ON_HOLD_DELIVERY | 송장등록 (보류해제) | 국내송장등록 (보류해제) |
| DELIVERED | 구매확정 | 구매확정 |

---

## DB 마이그레이션

### orders 테이블

```sql
ALTER TABLE orders ADD COLUMN shipping_type VARCHAR(20) DEFAULT 'DOMESTIC';
ALTER TABLE orders ADD COLUMN shipping_country VARCHAR(10);
ALTER TABLE orders ADD COLUMN shipping_state VARCHAR(100);
ALTER TABLE orders ADD COLUMN shipping_city VARCHAR(100);
```

### product_order 테이블

```sql
ALTER TABLE product_order ADD COLUMN international_tracking_number VARCHAR(100);
ALTER TABLE product_order ADD COLUMN international_delivery_company VARCHAR(100);
ALTER TABLE product_order ADD COLUMN international_invoice_registered_at DATETIME;
ALTER TABLE product_order ADD COLUMN forwarding_warehouse_code VARCHAR(50);
ALTER TABLE product_order ADD COLUMN arrived_at_warehouse_at DATETIME;
```

### 신규 테이블 — international_shipping_policy

```sql
CREATE TABLE international_shipping_policy (
    id BIGINT AUTO_INCREMENT PRIMARY KEY,
    country VARCHAR(10) NOT NULL UNIQUE,
    shipping_fee BIGINT NOT NULL DEFAULT 0,
    additional_fee_per_item BIGINT NOT NULL DEFAULT 0,
    forwarding_warehouse_address VARCHAR(500),
    forwarding_warehouse_code VARCHAR(50),
    forwarding_warehouse_contact VARCHAR(50),
    active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at DATETIME NOT NULL,
    updated_at DATETIME NOT NULL
);
```

---

## 구현 순서

### Phase 1: 기반 작업 (core 모듈)

1. `ShippingCountry` enum 생성
2. `Orders` 엔티티 필드 추가 + DB 마이그레이션
3. `ProductOrder` 국제송장 필드 추가 + DB 마이그레이션
4. `ProductOrderStatus` 상태 2개 추가
5. `InternationalShippingPolicy` 엔티티 + 마이그레이션
6. 기존 데이터 `shipping_type = 'DOMESTIC'` 일괄 업데이트

### Phase 2: 어드민 리스트 (super-admin)

1. `SearchCriteria`에 `shippingScope`, `shippingCountry` 추가
2. QueryDSL predicate 추가
3. 리스트 응답에 `shippingScope`, `shippingCountry` 추가
4. 엑셀 다운로드에 배송구분/국가 컬럼 추가

### Phase 3: 어드민 상세 + 액션 (super-admin)

1. 상세 응답에 `InternationalShippingInfo` 추가
2. 대행지 도착 API (`PATCH /product-orders/warehouse-arrival`)
3. 국제송장 등록 API (`PATCH /product-orders/international-shipment`)
4. 배송완료 로직 수정 (`INTERNATIONAL_SHIPPING` → `DELIVERED` 전이)
5. 벌크 송장 업로드 엑셀에 국제송장 컬럼 추가

### Phase 4: 앱 API (app-api)

1. `OrderSave.DeliveryInfo` 해외 필드 추가
2. 주문 생성 로직에서 해외배송 처리
3. 주문 상세 응답에 국제배송 정보 포함
4. 국가별 배송비 조회 API 추가

---

## 리스크 및 주의사항

### 높은 리스크

- **ProductOrderStatus 상태 추가**: 기존에 상태 기반으로 동작하는 로직이 많음 (취소, 환불, 에스크로 등). 새 상태가 기존 조건문에서 올바르게 처리되는지 전수 검토 필요.
- **에스크로 연동**: 해외배송 주문의 에스크로 처리 시 XPay API 호출 시점이 달라질 수 있음.

### 중간 리스크

- **교환/반품**: 해외배송 주문의 교환/반품 플로우는 국내와 크게 다름 (국제반송비, 반송 대행 등). 1차에서는 해외주문 교환/반품을 막고, 추후 지원하는 것을 권장.
- **배송비 계산**: `ShippingSnapshotFeeCalculator`에 국제배송비 계산 로직 추가 시 기존 국내배송비 계산에 영향 없도록 분리 필요.

### 낮은 리스크

- **리스트 필터 추가**: `shippingScope` predicate 추가는 기존 쿼리에 AND 조건 하나 추가 수준. 인덱스만 확인하면 됨.
- **상세 응답 확장**: `InternationalShippingInfo`는 null-safe하게 추가되므로 기존 프론트에 영향 없음.
