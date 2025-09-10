;; title: resource-allocator
;; version: 1.0.0
;; summary: Resource Allocator Smart Contract for Decentralized Asteroid Mining Investment Platform
;; description: Handles resource tracking, allocation proposals, voting, and automated settlement of mining resources

;; traits

;; token definitions

;; constants
(define-constant contract-owner tx-sender)
(define-constant err-owner-only (err u200))
(define-constant err-not-authorized (err u201))
(define-constant err-invalid-amount (err u202))
(define-constant err-invalid-proposal (err u203))
(define-constant err-proposal-not-found (err u204))
(define-constant err-proposal-expired (err u205))
(define-constant err-proposal-already-executed (err u206))
(define-constant err-already-voted (err u207))
(define-constant err-insufficient-resources (err u208))
(define-constant err-invalid-resource-type (err u209))
(define-constant err-proposal-not-approved (err u210))
(define-constant err-voting-period-active (err u211))
(define-constant err-not-shareholder (err u212))
(define-constant err-contract-paused (err u213))

;; Resource types constants
(define-constant resource-iron u1)
(define-constant resource-nickel u2)
(define-constant resource-platinum u3)
(define-constant resource-gold u4)
(define-constant resource-rare-earth u5)
(define-constant resource-water u6)

;; Proposal types
(define-constant proposal-type-distribute u1)
(define-constant proposal-type-sell u2)
(define-constant proposal-type-reserve u3)

;; Voting parameters
(define-constant voting-period u1440) ;; 1440 blocks (~1 week)
(define-constant min-approval-threshold u6000) ;; 60% approval required
(define-constant quorum-threshold u3000) ;; 30% quorum required

;; data vars
(define-data-var proposal-nonce uint u0)
(define-data-var total-shareholders uint u0)
(define-data-var contract-paused bool false)
(define-data-var operator principal contract-owner)

;; data maps
;; Resource inventory tracking
(define-map resource-inventory
  uint ;; resource-type
  { total-amount: uint, reserved-amount: uint, last-updated: uint })

;; Mining operation records
(define-map mining-records
  { operation-id: uint, resource-type: uint }
  { amount-mined: uint, mining-cost: uint, timestamp: uint, operator: principal })

;; Resource allocation proposals
(define-map allocation-proposals
  uint ;; proposal-id
  {
    proposer: principal,
    proposal-type: uint,
    resource-type: uint,
    amount: uint,
    recipient: (optional principal),
    price-per-unit: (optional uint),
    description: (string-ascii 256),
    created-at: uint,
    expires-at: uint,
    executed: bool,
    votes-for: uint,
    votes-against: uint,
    total-votes: uint
  })

;; Voting records
(define-map proposal-votes
  { proposal-id: uint, voter: principal }
  { vote: bool, voting-power: uint, timestamp: uint })

;; Shareholder registry (imports from mining-shares contract)
(define-map registered-shareholders principal uint) ;; principal -> shares

;; Resource allocation history
(define-map allocation-history
  uint ;; allocation-id
  {
    proposal-id: uint,
    resource-type: uint,
    amount-allocated: uint,
    recipient: principal,
    executed-at: uint,
    execution-method: uint
  })

;; Emergency reserves
(define-map emergency-reserves
  uint ;; resource-type
  { reserved-amount: uint, reason: (string-ascii 128), timestamp: uint })

;; Authorized mining operators
(define-map authorized-operators principal bool)

;; public functions

;; Register resources from mining operations
(define-public (register-mined-resources (operation-id uint) (resource-type uint) (amount uint) (mining-cost uint))
  (let (
    (caller tx-sender)
    (current-inventory (default-to 
      { total-amount: u0, reserved-amount: u0, last-updated: u0 } 
      (map-get? resource-inventory resource-type)))
    (new-total (+ (get total-amount current-inventory) amount))
  )
    (asserts! (not (var-get contract-paused)) err-contract-paused)
    (asserts! (default-to false (map-get? authorized-operators caller)) err-not-authorized)
    (asserts! (> amount u0) err-invalid-amount)
    (asserts! (<= resource-type resource-water) err-invalid-resource-type)
    
    ;; Update resource inventory
    (map-set resource-inventory resource-type 
      (merge current-inventory {
        total-amount: new-total,
        last-updated: block-height
      }))
    
    ;; Record mining operation
    (map-set mining-records 
      { operation-id: operation-id, resource-type: resource-type }
      { amount-mined: amount, mining-cost: mining-cost, timestamp: block-height, operator: caller })
    
    (ok true)
  )
)

;; Create resource allocation proposal
(define-public (propose-allocation 
  (proposal-type uint) 
  (resource-type uint) 
  (amount uint) 
  (recipient (optional principal)) 
  (price-per-unit (optional uint)) 
  (description (string-ascii 256)))
  (let (
    (caller tx-sender)
    (caller-shares (default-to u0 (map-get? registered-shareholders caller)))
    (current-nonce (var-get proposal-nonce))
    (new-nonce (+ current-nonce u1))
    (expires-at (+ block-height voting-period))
    (current-inventory (default-to 
      { total-amount: u0, reserved-amount: u0, last-updated: u0 } 
      (map-get? resource-inventory resource-type)))
    (available-amount (- (get total-amount current-inventory) (get reserved-amount current-inventory)))
  )
    (asserts! (not (var-get contract-paused)) err-contract-paused)
    (asserts! (> caller-shares u0) err-not-shareholder)
    (asserts! (<= proposal-type proposal-type-reserve) err-invalid-proposal)
    (asserts! (<= resource-type resource-water) err-invalid-resource-type)
    (asserts! (> amount u0) err-invalid-amount)
    (asserts! (>= available-amount amount) err-insufficient-resources)
    
    ;; Create proposal
    (map-set allocation-proposals new-nonce {
      proposer: caller,
      proposal-type: proposal-type,
      resource-type: resource-type,
      amount: amount,
      recipient: recipient,
      price-per-unit: price-per-unit,
      description: description,
      created-at: block-height,
      expires-at: expires-at,
      executed: false,
      votes-for: u0,
      votes-against: u0,
      total-votes: u0
    })
    
    ;; Reserve resources for the proposal
    (map-set resource-inventory resource-type 
      (merge current-inventory {
        reserved-amount: (+ (get reserved-amount current-inventory) amount)
      }))
    
    ;; Update nonce
    (var-set proposal-nonce new-nonce)
    
    (ok new-nonce)
  )
)

;; Vote on allocation proposal
(define-public (vote-on-proposal (proposal-id uint) (support bool))
  (let (
    (caller tx-sender)
    (caller-shares (default-to u0 (map-get? registered-shareholders caller)))
    (proposal (unwrap! (map-get? allocation-proposals proposal-id) err-proposal-not-found))
    (existing-vote (map-get? proposal-votes { proposal-id: proposal-id, voter: caller }))
    (current-votes-for (get votes-for proposal))
    (current-votes-against (get votes-against proposal))
    (current-total-votes (get total-votes proposal))
  )
    (asserts! (not (var-get contract-paused)) err-contract-paused)
    (asserts! (> caller-shares u0) err-not-shareholder)
    (asserts! (< block-height (get expires-at proposal)) err-proposal-expired)
    (asserts! (not (get executed proposal)) err-proposal-already-executed)
    (asserts! (is-none existing-vote) err-already-voted)
    
    ;; Record vote
    (map-set proposal-votes 
      { proposal-id: proposal-id, voter: caller }
      { vote: support, voting-power: caller-shares, timestamp: block-height })
    
    ;; Update proposal vote counts
    (map-set allocation-proposals proposal-id 
      (merge proposal {
        votes-for: (if support (+ current-votes-for caller-shares) current-votes-for),
        votes-against: (if support current-votes-against (+ current-votes-against caller-shares)),
        total-votes: (+ current-total-votes caller-shares)
      }))
    
    (ok true)
  )
)

;; Execute approved allocation proposal
(define-public (execute-allocation (proposal-id uint))
  (let (
    (caller tx-sender)
    (proposal (unwrap! (map-get? allocation-proposals proposal-id) err-proposal-not-found))
    (total-shares (var-get total-shareholders))
    (votes-for (get votes-for proposal))
    (total-votes (get total-votes proposal))
    (approval-percentage (if (> total-votes u0) (/ (* votes-for u10000) total-votes) u0))
    (quorum-percentage (if (> total-shares u0) (/ (* total-votes u10000) total-shares) u0))
    (resource-type (get resource-type proposal))
    (amount (get amount proposal))
    (current-inventory (unwrap! (map-get? resource-inventory resource-type) err-insufficient-resources))
  )
    (asserts! (not (var-get contract-paused)) err-contract-paused)
    (asserts! (>= block-height (get expires-at proposal)) err-voting-period-active)
    (asserts! (not (get executed proposal)) err-proposal-already-executed)
    (asserts! (>= approval-percentage min-approval-threshold) err-proposal-not-approved)
    (asserts! (>= quorum-percentage quorum-threshold) err-proposal-not-approved)
    
    ;; Mark proposal as executed
    (map-set allocation-proposals proposal-id 
      (merge proposal { executed: true }))
    
    ;; Update resource inventory
    (map-set resource-inventory resource-type 
      (merge current-inventory {
        total-amount: (- (get total-amount current-inventory) amount),
        reserved-amount: (- (get reserved-amount current-inventory) amount)
      }))
    
    ;; Record allocation history
    (map-set allocation-history proposal-id {
      proposal-id: proposal-id,
      resource-type: resource-type,
      amount-allocated: amount,
      recipient: (default-to tx-sender (get recipient proposal)),
      executed-at: block-height,
      execution-method: (get proposal-type proposal)
    })
    
    (ok true)
  )
)

;; Emergency resource reserve function
(define-public (emergency-reserve (resource-type uint) (amount uint) (reason (string-ascii 128)))
  (let (
    (caller tx-sender)
    (current-inventory (unwrap! (map-get? resource-inventory resource-type) err-insufficient-resources))
    (available-amount (- (get total-amount current-inventory) (get reserved-amount current-inventory)))
  )
    (asserts! (is-eq caller contract-owner) err-owner-only)
    (asserts! (> amount u0) err-invalid-amount)
    (asserts! (>= available-amount amount) err-insufficient-resources)
    
    ;; Update inventory reserves
    (map-set resource-inventory resource-type 
      (merge current-inventory {
        reserved-amount: (+ (get reserved-amount current-inventory) amount)
      }))
    
    ;; Record emergency reserve
    (map-set emergency-reserves resource-type {
      reserved-amount: amount,
      reason: reason,
      timestamp: block-height
    })
    
    (ok true)
  )
)

;; Update shareholder registry from mining-shares contract
(define-public (update-shareholder (shareholder principal) (shares uint))
  (begin
    (asserts! (is-eq tx-sender (var-get operator)) err-owner-only)
    (map-set registered-shareholders shareholder shares)
    (ok true)
  )
)

;; Authorize mining operator
(define-public (authorize-operator (operator principal))
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (map-set authorized-operators operator true)
    (ok true)
  )
)

;; Pause contract operations
(define-public (pause-contract)
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (var-set contract-paused true)
    (ok true)
  )
)

;; Resume contract operations
(define-public (resume-contract)
  (begin
    (asserts! (is-eq tx-sender contract-owner) err-owner-only)
    (var-set contract-paused false)
    (ok true)
  )
)

;; read only functions

;; Get resource inventory
(define-read-only (get-resource-inventory (resource-type uint))
  (map-get? resource-inventory resource-type)
)

;; Get all resource types inventory
(define-read-only (get-all-resources)
  (ok {
    iron: (map-get? resource-inventory resource-iron),
    nickel: (map-get? resource-inventory resource-nickel),
    platinum: (map-get? resource-inventory resource-platinum),
    gold: (map-get? resource-inventory resource-gold),
    rare-earth: (map-get? resource-inventory resource-rare-earth),
    water: (map-get? resource-inventory resource-water)
  })
)

;; Get proposal details
(define-read-only (get-proposal (proposal-id uint))
  (map-get? allocation-proposals proposal-id)
)

;; Get vote information
(define-read-only (get-vote (proposal-id uint) (voter principal))
  (map-get? proposal-votes { proposal-id: proposal-id, voter: voter })
)

;; Get mining record
(define-read-only (get-mining-record (operation-id uint) (resource-type uint))
  (map-get? mining-records { operation-id: operation-id, resource-type: resource-type })
)

;; Get allocation history
(define-read-only (get-allocation-history (allocation-id uint))
  (map-get? allocation-history allocation-id)
)

;; Get emergency reserves
(define-read-only (get-emergency-reserves (resource-type uint))
  (map-get? emergency-reserves resource-type)
)

;; Check if address is authorized operator
(define-read-only (is-authorized-operator (operator principal))
  (default-to false (map-get? authorized-operators operator))
)

;; Get shareholder info
(define-read-only (get-shareholder-info (shareholder principal))
  (ok {
    shares: (default-to u0 (map-get? registered-shareholders shareholder)),
    is-registered: (> (default-to u0 (map-get? registered-shareholders shareholder)) u0)
  })
)

;; Check if contract is paused
(define-read-only (is-paused)
  (var-get contract-paused)
)

;; Get current proposal nonce
(define-read-only (get-proposal-nonce)
  (var-get proposal-nonce)
)

;; Calculate available resources for allocation
(define-read-only (get-available-resources (resource-type uint))
  (match (map-get? resource-inventory resource-type)
    inventory (ok (- (get total-amount inventory) (get reserved-amount inventory)))
    (err err-invalid-resource-type)
  )
)

;; Get proposal approval status
(define-read-only (get-proposal-status (proposal-id uint))
  (match (map-get? allocation-proposals proposal-id)
    proposal 
      (let (
        (total-shares (var-get total-shareholders))
        (votes-for (get votes-for proposal))
        (total-votes (get total-votes proposal))
        (approval-percentage (if (> total-votes u0) (/ (* votes-for u10000) total-votes) u0))
        (quorum-percentage (if (> total-shares u0) (/ (* total-votes u10000) total-shares) u0))
      )
        (ok {
          approval-percentage: approval-percentage,
          quorum-percentage: quorum-percentage,
          is-approved: (and 
            (>= approval-percentage min-approval-threshold)
            (>= quorum-percentage quorum-threshold)),
          voting-ended: (>= block-height (get expires-at proposal)),
          executed: (get executed proposal)
        })
      )
    (err err-proposal-not-found)
  )
)

;; private functions

;; Calculate voting power based on shareholding
(define-private (calculate-voting-power (shareholder principal))
  (default-to u0 (map-get? registered-shareholders shareholder))
)
