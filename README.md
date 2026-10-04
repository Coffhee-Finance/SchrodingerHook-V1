# Coffhee Finance — The Confidential Layer for Onchain Finance

Coffhee Finance is a confidential DeFi protocol on Arbitrum that enables users to trade and manage tokenized assets without publicly exposing their complete financial strategies.

Coffhee's encrypted AMM is built around the **Schrödinger Hook for Uniswap v4**, combining confidential computation with programmable liquidity and trading logic. By leveraging Fully Homomorphic Encryption (FHE), Coffhee aims to protect sensitive financial information—such as portfolio allocations, position data, and strategy parameters—while enabling automated trading and liquidity management.

## Architecture Overview

- **Confidential AMM:** The Schrödinger Hook extends Uniswap v4 with privacy-focused trading, liquidity management, and automated strategy execution.
- **ePerps:** Represents supported perpetual positions originating from Hyperliquid for integration with Arbitrum DeFi.
- **eStocks:** Confidential representations of supported tokenized stocks from Robinhood Chain.
- **eMeme:** Confidential meme tokens and ERC-20 assets that can participate in Coffhee markets.
- **Cross-Chain Integration:** LayerZero-based infrastructure supports asset connectivity across ecosystems.
- **Confidential Computation:** FHE-based components enable selected financial data and strategy parameters to be processed while encrypted.

## Why Coffhee?

Public blockchains provide transparent markets, but that transparency can expose traders' positions, portfolio allocations, and strategies. Coffhee aims to preserve the composability of onchain finance while giving users greater control over sensitive financial information.

**The vision:** Make confidentiality a core feature of tokenized stocks, perpetuals, tokens, and decentralized markets.

**Current status:** Coffhee is under development on Arbitrum testnet as part of the Arbitrum Open House Online Buildathon. Mainnet deployment is targeted for Q1 2027, subject to testing, security reviews, and integration readiness.

