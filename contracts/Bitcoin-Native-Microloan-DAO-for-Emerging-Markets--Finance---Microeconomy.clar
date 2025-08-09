(define-constant ERR-NOT-AUTHORIZED (err u100))
(define-constant ERR-INSUFFICIENT-FUNDS (err u101))
(define-constant ERR-LOAN-NOT-FOUND (err u102))
(define-constant ERR-INVALID-AMOUNT (err u103))
(define-constant ERR-LOAN-ACTIVE (err u104))
(define-constant ERR-LOAN-NOT-COMPLETED (err u105))
(define-constant ERR-MAX-EXTENSIONS-REACHED (err u106))

(define-data-var dao-treasury uint u0)
(define-data-var min-collateral uint u1000000) ;; 0.01 BTC in sats
(define-data-var interest-rate uint u500) ;; 5% represented as basis points
(define-data-var extension-fee uint u100000) ;; 0.001 BTC in sats
(define-data-var max-extensions uint u3)

(define-map loans 
    { loan-id: uint }
    {
        borrower: principal,
        amount: uint,
        collateral: uint,
        due-date: uint,
        status: (string-ascii 20),
        repaid-amount: uint
    }
)

(define-map borrower-scores
    { borrower: principal }
    { score: uint }
)

(define-map loan-extensions
    { loan-id: uint }
    { extensions-used: uint }
)

(define-data-var loan-counter uint u0)

(define-public (initialize-dao)
    (begin
        (var-set dao-treasury u0)
        (var-set loan-counter u0)
        (ok true)))

(define-public (request-loan (amount uint) (collateral uint) (duration uint))
    (let ((loan-id (+ (var-get loan-counter) u1)))
        (asserts! (>= collateral (var-get min-collateral)) ERR-INVALID-AMOUNT)
        (asserts! (> amount u0) ERR-INVALID-AMOUNT)
        (try! (stx-transfer? collateral tx-sender (as-contract tx-sender)))
        (map-set loans 
            { loan-id: loan-id }
            {
                borrower: tx-sender,
                amount: amount,
                collateral: collateral,
                due-date: (+ burn-block-height duration),
                status: "ACTIVE",
                repaid-amount: u0
            }
        )
        (var-set loan-counter loan-id)
        (ok loan-id)))

(define-public (repay-loan (loan-id uint) (payment uint))
    (let ((loan (unwrap! (map-get? loans { loan-id: loan-id }) ERR-LOAN-NOT-FOUND))
          (current-repaid (get repaid-amount loan)))
        (asserts! (is-eq (get borrower loan) tx-sender) ERR-NOT-AUTHORIZED)
        (asserts! (is-eq (get status loan) "ACTIVE") ERR-LOAN-NOT-FOUND)
        (try! (stx-transfer? payment tx-sender (as-contract tx-sender)))
        (map-set loans
            { loan-id: loan-id }
            (merge loan { 
                repaid-amount: (+ current-repaid payment),
                status: (if (>= (+ current-repaid payment) (get amount loan)) 
                    "COMPLETED"
                    "ACTIVE")
            })
        )
        (ok true)))

(define-read-only (get-loan (loan-id uint))
    (map-get? loans { loan-id: loan-id }))

(define-read-only (get-borrower-score (borrower principal))
    (default-to { score: u0 } (map-get? borrower-scores { borrower: borrower })))

(define-public (liquidate-loan (loan-id uint))
    (let ((loan (unwrap! (map-get? loans { loan-id: loan-id }) ERR-LOAN-NOT-FOUND)))
        (asserts! (>= burn-block-height (get due-date loan)) ERR-NOT-AUTHORIZED)
        (asserts! (is-eq (get status loan) "ACTIVE") ERR-LOAN-NOT-FOUND)
        (map-set loans
            { loan-id: loan-id }
            (merge loan { status: "LIQUIDATED" })
        )
        (try! (as-contract (stx-transfer? (get collateral loan) tx-sender (get borrower loan))))
        (ok true)))
(define-public (update-borrower-score (borrower principal) (new-score uint))
    (begin
        (asserts! (is-eq tx-sender (as-contract tx-sender)) ERR-NOT-AUTHORIZED)
        (map-set borrower-scores
            { borrower: borrower }
            { score: new-score }
        )
        (ok true)))

(define-public (release-collateral (loan-id uint))
    (let ((loan (unwrap! (map-get? loans { loan-id: loan-id }) ERR-LOAN-NOT-FOUND)))
        (asserts! (is-eq (get borrower loan) tx-sender) ERR-NOT-AUTHORIZED)
        (asserts! (is-eq (get status loan) "COMPLETED") ERR-LOAN-NOT-COMPLETED)
        (map-set loans
            { loan-id: loan-id }
            (merge loan { status: "COLLATERAL_RELEASED" })
        )
        (try! (as-contract (stx-transfer? (get collateral loan) tx-sender (get borrower loan))))
        (ok true)))

(define-public (extend-loan (loan-id uint) (extension-duration uint))
    (let ((loan (unwrap! (map-get? loans { loan-id: loan-id }) ERR-LOAN-NOT-FOUND))
          (current-extensions (get extensions-used (default-to { extensions-used: u0 } 
              (map-get? loan-extensions { loan-id: loan-id })))))
        (asserts! (is-eq (get borrower loan) tx-sender) ERR-NOT-AUTHORIZED)
        (asserts! (is-eq (get status loan) "ACTIVE") ERR-LOAN-NOT-FOUND)
        (asserts! (< current-extensions (var-get max-extensions)) ERR-MAX-EXTENSIONS-REACHED)
        (try! (stx-transfer? (var-get extension-fee) tx-sender (as-contract tx-sender)))
        (map-set loans
            { loan-id: loan-id }
            (merge loan { due-date: (+ (get due-date loan) extension-duration) })
        )
        (map-set loan-extensions
            { loan-id: loan-id }
            { extensions-used: (+ current-extensions u1) }
        )
        (var-set dao-treasury (+ (var-get dao-treasury) (var-get extension-fee)))
        (ok true)))