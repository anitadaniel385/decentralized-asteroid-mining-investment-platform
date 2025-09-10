;; title: mining-shares
;; version: 1.0.0
;; summary: Mining Shares Smart Contract for Decentralized Asteroid Mining Investment Platform
;; description: Implements fungible token system for mining shares with investment tracking and dividend distribution

;; traits
(use-trait ft-trait .sip-010-trait.sip-010-trait)

;; token definitions
(define-fungible-token mining-shares)

;; constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u100))
(define-constant err-not-authorized (err u101))
(define-constant err-insufficient-balance (err u102))
(define-constant err-invalid-amount (err u103))
(define-constant err-already-registered (err u104))
(define-constant err-not-registered (err u105))
(define-constant err-transfer-failed (err u106))
(define-constant err-mint-failed (err u107))
(define-constant err-burn-failed (err u108))
(define-constant err-insufficient-dividends (err u109))
(define-constant err-no-dividends (err u110))

;; Maximum shares that can be issued
(define-constant max-supply u1000000000000) ;; 1 trillion shares with 6 decimals
(define-constant decimals u6)

;; Minimum investment amount in microSTX
(define-constant min-investment u1000000) ;; 1 STX

;; data vars
(define-data-var total-supply uint u0)
(define-data-var share-price uint u100) ;; Price per share in microSTX
(define-data-var dividend-pool uint u0)
(define-data-var dividend-round uint u0)
(define-data-var paused bool false)
(define-data-var operator principal contract-owner)

;; data maps
;; Track individual shareholdings
(define-map shareholdings principal uint)

;; Track investor registration status
(define-map registered-investors principal bool)

;; Investment history tracking
(define-map investment-history 
  { investor: principal, round: uint }
  { amount: uint, shares: uint, timestamp: uint })

;; Dividend tracking per investor per round
(define-map dividend-claims
  { investor: principal, round: uint }
  { claimed: bool, amount: uint })

;; Track unclaimed dividends per investor
(define-map unclaimed-dividends principal uint)

;; Mining operation metrics
(define-map mining-operations
  uint
  { total-mined: uint, operation-cost: uint, profit: uint, timestamp: uint })

;; Authorized operators for mining operations
(define-map authorized-operators principal bool)

;; public functions

;; Register as an investor
(define-public (register-investor)
  (let (
    (caller tx-sender)
  )
    (asserts! (not (default-to false (map-get? registered-investors caller))) err-already-registered)
    (map-set registered-investors caller true)
    (ok true)
  )
)

;; Buy mining shares with STX
(define-public (buy-shares (stx-amount uint))
  (let (
    (caller tx-sender)
    (current-price (var-get share-price))
    (shares-to-mint (/ (* stx-amount (pow u10 decimals)) current-price))
    (current-supply (var-get total-supply))
    (investment-round (+ (var-get dividend-round) u1))
  )
    (asserts! (not (var-get paused)) err-not-authorized)
    (asserts! (>= stx-amount min-investment) err-invalid-amount)
    (asserts! (default-to false (map-get? registered-investors caller)) err-not-registered)
    (asserts! (<= (+ current-supply shares-to-mint) max-supply) err-invalid-amount)
    
    ;; Transfer STX to contract
    (try! (stx-transfer? stx-amount caller (as-contract tx-sender)))
    
    ;; Mint shares to investor
    (try! (ft-mint? mining-shares shares-to-mint caller))
    
    ;; Update total supply
    (var-set total-supply (+ current-supply shares-to-mint))
    
    ;; Update investor shareholding
    (map-set shareholdings caller 
      (+ (default-to u0 (map-get? shareholdings caller)) shares-to-mint))
    
    ;; Record investment history
    (map-set investment-history 
      { investor: caller, round: investment-round }
      { amount: stx-amount, shares: shares-to-mint, timestamp: block-height })
    
    (ok shares-to-mint)
  )
)

;; Transfer shares between investors
(define-public (transfer-shares (amount uint) (recipient principal))
  (let (
    (caller tx-sender)
    (sender-balance (default-to u0 (map-get? shareholdings caller)))
    (recipient-balance (default-to u0 (map-get? shareholdings recipient)))
  )
    (asserts! (not (var-get paused)) err-not-authorized)
    (asserts! (>= sender-balance amount) err-insufficient-balance)
    (asserts! (default-to false (map-get? registered-investors recipient)) err-not-registered)
    
    ;; Transfer fungible tokens
    (try! (ft-transfer? mining-shares amount caller recipient))
    
    ;; Update shareholding maps
    (map-set shareholdings caller (- sender-balance amount))
    (map-set shareholdings recipient (+ recipient-balance amount))
    
    (ok true)
  )
)

;; Distribute mining profits as dividends
(define-public (distribute-dividends (total-profit uint))
  (let (
    (caller tx-sender)
    (current-round (var-get dividend-round))
    (new-round (+ current-round u1))
    (current-pool (var-get dividend-pool))
  )
    (asserts! (is-eq caller (var-get operator)) err-owner-only)
    (asserts! (> total-profit u0) err-invalid-amount)
    
    ;; Update dividend pool and round
    (var-set dividend-pool (+ current-pool total-profit))
    (var-set dividend-round new-round)
    
    ;; Record mining operation
    (map-set mining-operations new-round 
      { total-mined: total-profit, operation-cost: u0, profit: total-profit, timestamp: block-height })
    
    (ok new-round)
  )
)

;; Claim accumulated dividends
(define-public (claim-dividends)
  (let (
    (caller tx-sender)
    (investor-shares (default-to u0 (map-get? shareholdings caller)))
    (total-shares (var-get total-supply))
    (current-round (var-get dividend-round))
    (pool-amount (var-get dividend-pool))
    (dividend-amount (if (> total-shares u0) 
                       (/ (* investor-shares pool-amount) total-shares) u0))
    (unclaimed-amount (default-to u0 (map-get? unclaimed-dividends caller)))
    (total-claim (+ dividend-amount unclaimed-amount))
  )
    (asserts! (default-to false (map-get? registered-investors caller)) err-not-registered)
    (asserts! (> investor-shares u0) err-insufficient-balance)
    (asserts! (> total-claim u0) err-no-dividends)
    
    ;; Check if already claimed for current round
    (asserts! (not (default-to false 
      (get claimed (map-get? dividend-claims { investor: caller, round: current-round }))))
      err-already-registered)
    
    ;; Transfer dividends to investor
    (try! (as-contract (stx-transfer? total-claim tx-sender caller)))
    
    ;; Mark as claimed for current round
    (map-set dividend-claims 
      { investor: caller, round: current-round }
      { claimed: true, amount: total-claim })
    
    ;; Clear unclaimed dividends
    (map-delete unclaimed-dividends caller)
    
    ;; Update dividend pool
    (var-set dividend-pool (- pool-amount dividend-amount))
    
    (ok total-claim)
  )
)

;; Emergency pause functionality
(define-public (pause-contract)
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (var-set paused true)
    (ok true)
  )
)

;; Resume contract operations
(define-public (resume-contract)
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (var-set paused false)
    (ok true)
  )
)

;; Set new operator
(define-public (set-operator (new-operator principal))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (var-set operator new-operator)
    (ok true)
  )
)

;; Update share price
(define-public (update-share-price (new-price uint))
  (begin
    (asserts! (is-eq tx-sender (var-get operator)) err-owner-only)
    (asserts! (> new-price u0) err-invalid-amount)
    (var-set share-price new-price)
    (ok true)
  )
)

;; read only functions

;; Get total supply of shares
(define-read-only (get-total-supply)
  (ok (var-get total-supply))
)

;; Get investor shareholding
(define-read-only (get-shareholding (investor principal))
  (ok (default-to u0 (map-get? shareholdings investor)))
)

;; Check if investor is registered
(define-read-only (is-registered (investor principal))
  (default-to false (map-get? registered-investors investor))
)

;; Get current share price
(define-read-only (get-share-price)
  (var-get share-price)
)

;; Get dividend information
(define-read-only (get-dividend-info)
  (ok {
    pool: (var-get dividend-pool),
    round: (var-get dividend-round),
    total-shares: (var-get total-supply)
  })
)

;; Get unclaimed dividends for investor
(define-read-only (get-unclaimed-dividends (investor principal))
  (let (
    (investor-shares (default-to u0 (map-get? shareholdings investor)))
    (total-shares (var-get total-supply))
    (pool-amount (var-get dividend-pool))
    (dividend-amount (if (> total-shares u0)
                       (/ (* investor-shares pool-amount) total-shares) u0))
  )
    (ok dividend-amount)
  )
)

;; Get investment history
(define-read-only (get-investment-history (investor principal) (round uint))
  (map-get? investment-history { investor: investor, round: round })
)

;; Get mining operation details
(define-read-only (get-mining-operation (round uint))
  (map-get? mining-operations round)
)

;; Check if contract is paused
(define-read-only (is-paused)
  (var-get paused)
)

;; Get contract operator
(define-read-only (get-operator)
  (var-get operator)
)

;; Get token metadata
(define-read-only (get-name)
  (ok "Mining Shares")
)

(define-read-only (get-symbol)
  (ok "MINES")
)

(define-read-only (get-decimals)
  (ok decimals)
)

;; Get token balance (implementing SIP-010)
(define-read-only (get-balance (account principal))
  (ok (ft-get-balance mining-shares account))
)

;; private functions

;; Calculate proportional dividend for investor
(define-private (calculate-dividend (investor-shares uint) (total-shares uint) (pool-amount uint))
  (if (> total-shares u0)
    (/ (* investor-shares pool-amount) total-shares)
    u0
  )
)
