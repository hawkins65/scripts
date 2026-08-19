#!/usr/bin/env python3
"""
Sui Validator Gas Price Analysis Script

This script pulls validator voting power and gas prices from Sui network,
calculates vote power weighted gas prices, and generates statistical analysis
with visualization.

Requirements:
- requests
- pandas
- matplotlib
- numpy
"""

import requests
import json
import pandas as pd
import matplotlib.pyplot as plt
import numpy as np
from typing import Dict, List, Tuple, Optional
import argparse
from datetime import datetime

class SuiValidatorAnalyzer:
    def __init__(self, rpc_url: str = "https://fullnode.mainnet.sui.io:443"):
        """
        Initialize the Sui Validator Analyzer
        
        Args:
            rpc_url: Sui RPC endpoint URL
        """
        self.rpc_url = rpc_url
        self.session = requests.Session()
        self.session.headers.update({
            'Content-Type': 'application/json'
        })
    
    def rpc_call(self, method: str, params: List = None) -> Dict:
        """
        Make RPC call to Sui node
        
        Args:
            method: RPC method name
            params: Method parameters
            
        Returns:
            RPC response data
        """
        payload = {
            "jsonrpc": "2.0",
            "id": 1,
            "method": method,
            "params": params or []
        }
        
        try:
            response = self.session.post(self.rpc_url, json=payload, timeout=30)
            response.raise_for_status()
            data = response.json()
            
            if 'error' in data:
                raise Exception(f"RPC Error: {data['error']}")
                
            return data.get('result', {})
            
        except requests.exceptions.RequestException as e:
            raise Exception(f"Request failed: {e}")
    
    def get_validators_apy(self) -> List[Dict]:
        """
        Get validator information including voting power
        
        Returns:
            List of validator data
        """
        try:
            result = self.rpc_call("suix_getValidatorsApy")
            return result.get('apys', [])
        except Exception as e:
            print(f"Error fetching validator APY data: {e}")
            return []
    
    def get_latest_sui_system_state(self) -> Dict:
        """
        Get latest Sui system state including validator info
        
        Returns:
            System state data
        """
        # Try multiple methods for getting system state
        methods_to_try = [
            "suix_getLatestSuiSystemState",
            "sui_getLatestSuiSystemState", 
            "suix_getValidators",
            "sui_getValidators"
        ]
        
        for method in methods_to_try:
            try:
                print(f"Trying method: {method}")
                result = self.rpc_call(method)
                if result:
                    print(f"Success with method: {method}")
                    return result
            except Exception as e:
                print(f"Method {method} failed: {e}")
                continue
        
        print("All system state methods failed, trying alternative approach...")
        return self._try_alternative_validator_fetch()
    
    def _try_alternative_validator_fetch(self) -> Dict:
        """
        Try alternative methods to fetch validator data
        """
        alternative_methods = [
            ("sui_getValidatorsApy", []),
            ("suix_getValidatorsApy", []),
            ("sui_getCommittee", []),
            ("suix_getCommittee", []),
            ("sui_getLatestCheckpointSequenceNumber", [])
        ]
        
        for method, params in alternative_methods:
            try:
                print(f"Trying alternative method: {method}")
                result = self.rpc_call(method, params)
                if result:
                    print(f"Got response from {method}")
                    # Try to extract validator info from response
                    if isinstance(result, dict):
                        if 'activeValidators' in result:
                            return result
                        elif 'apys' in result:
                            # Convert APY format to system state format
                            return {'activeValidators': result['apys']}
                        elif 'validators' in result:
                            return {'activeValidators': result['validators']}
                    elif isinstance(result, list):
                        return {'activeValidators': result}
            except Exception as e:
                print(f"Alternative method {method} failed: {e}")
                continue
        
        return {}

    def get_reference_gas_price(self) -> int:
        """
        Get current reference gas price
        
        Returns:
            Reference gas price in MIST
        """
        methods_to_try = [
            "suix_getReferenceGasPrice",
            "sui_getReferenceGasPrice",
            "sui_getGasPrice",
            "suix_getGasPrice"
        ]
        
        for method in methods_to_try:
            try:
                print(f"Trying gas price method: {method}")
                result = self.rpc_call(method)
                if result is not None:
                    print(f"Got gas price from {method}: {result}")
                    return int(result)
            except Exception as e:
                print(f"Gas price method {method} failed: {e}")
                continue
        
        print("All gas price methods failed, using default value")
        return 1000  # Default fallback value

    def debug_rpc_methods(self) -> List[str]:
        """
        Try to discover available RPC methods
        """
        print("Attempting to discover available RPC methods...")
        
        # Try to get supported methods
        discovery_methods = [
            "rpc.discover",
            "system.listMethods", 
            "sui_getSupportedMethods",
            "suix_getSupportedMethods"
        ]
        
        for method in discovery_methods:
            try:
                result = self.rpc_call(method)
                if result:
                    print(f"Available methods discovered via {method}:")
                    if isinstance(result, list):
                        for m in result:
                            print(f"  - {m}")
                        return result
                    elif isinstance(result, dict):
                        methods = result.get('methods', [])
                        for m in methods:
                            print(f"  - {m}")
                        return methods
            except Exception as e:
                print(f"Discovery method {method} failed: {e}")
        
        print("Could not discover available methods")
        return []
    
    def get_validator_gas_prices(self, validators: List[Dict]) -> Dict[str, int]:
        """
        Extract gas prices from validator data
        
        Args:
            validators: List of validator objects
            
        Returns:
            Dictionary mapping validator addresses to gas prices
        """
        gas_prices = {}
        
        for i, validator in enumerate(validators):
            address = (validator.get('suiAddress') or 
                      validator.get('address') or 
                      validator.get('validator_address') or 
                      f"validator_{i}")
            
            # Try different field names for gas price
            gas_price = (validator.get('nextEpochGasPrice') or
                        validator.get('gasPrice') or
                        validator.get('gas_price') or
                        validator.get('nextGasPrice') or
                        validator.get('current_gas_price') or 0)
            
            try:
                gas_price = int(gas_price)
                if gas_price > 0:
                    gas_prices[address] = gas_price
            except (ValueError, TypeError):
                pass
        
        return gas_prices
    
    def calculate_voting_power(self, validators: List[Dict]) -> Dict[str, float]:
        """
        Calculate voting power for each validator
        
        Args:
            validators: List of validator objects
            
        Returns:
            Dictionary mapping validator addresses to voting power percentages
        """
        voting_powers = {}
        total_stake = 0
        
        # Calculate total stake - try different field names
        for validator in validators:
            stake = (validator.get('stakingPoolSuiBalance') or
                    validator.get('stake') or
                    validator.get('total_stake') or 0)
            try:
                stake = int(stake)
                total_stake += stake
            except (ValueError, TypeError):
                pass
        
        if total_stake == 0:
            print("Warning: Total stake is 0, assigning equal voting power")
            equal_power = 100.0 / len(validators) if validators else 0
            for i, validator in enumerate(validators):
                address = (validator.get('suiAddress') or 
                          validator.get('address') or 
                          f"validator_{i}")
                voting_powers[address] = equal_power
            return voting_powers
        
        # Calculate voting power percentages
        for i, validator in enumerate(validators):
            address = (validator.get('suiAddress') or 
                      validator.get('address') or 
                      f"validator_{i}")
            
            stake = (validator.get('stakingPoolSuiBalance') or
                    validator.get('stake') or
                    validator.get('total_stake') or 0)
            
            try:
                stake = int(stake)
                voting_power = (stake / total_stake * 100) if total_stake > 0 else 0
            except (ValueError, TypeError):
                voting_power = 0
                
            voting_powers[address] = voting_power
        
        return voting_powers
    
    def collect_data(self) -> Tuple[pd.DataFrame, Dict]:
        """
        Collect all validator data
        
        Returns:
            DataFrame with validator data and metadata dictionary
        """
        print("Starting data collection...")
        
        # First, try to discover available methods
        self.debug_rpc_methods()
        
        print("\nFetching Sui system state...")
        system_state = self.get_latest_sui_system_state()
        
        if not system_state:
            raise Exception("Failed to fetch system state from any available method")
        
        # Extract validators from different possible response formats
        validators = []
        if 'activeValidators' in system_state:
            validators = system_state['activeValidators']
        elif 'validators' in system_state:
            validators = system_state['validators']
        elif isinstance(system_state, list):
            validators = system_state
        else:
            # Try to find validator data in any nested structure
            for key, value in system_state.items():
                if isinstance(value, list) and value and 'suiAddress' in str(value[0]):
                    validators = value
                    break
        
        if not validators:
            print("System state structure:")
            print(json.dumps(system_state, indent=2, default=str)[:1000] + "...")
            raise Exception("No validators found in system state. Check the structure above.")
        
        print(f"Found {len(validators)} validators")
        
        # Get reference gas price
        ref_gas_price = self.get_reference_gas_price()
        print(f"Reference gas price: {ref_gas_price} MIST")
        
        # Calculate voting powers
        voting_powers = self.calculate_voting_power(validators)
        
        # Get gas prices
        gas_prices = self.get_validator_gas_prices(validators)
        
        # Create DataFrame
        data = []
        for i, validator in enumerate(validators):
            # Handle different validator data formats
            address = (validator.get('suiAddress') or 
                      validator.get('address') or 
                      validator.get('validator_address') or 
                      f"validator_{i}")
            
            name = (validator.get('name') or 
                   validator.get('validator_name') or 
                   address[:8] + '...')
            
            # Try different field names for stake
            stake = (validator.get('stakingPoolSuiBalance') or
                    validator.get('stake') or
                    validator.get('total_stake') or 0)
            
            try:
                stake = int(stake)
            except (ValueError, TypeError):
                stake = 0
            
            # Try different field names for commission
            commission = (validator.get('commissionRate') or
                         validator.get('commission_rate') or
                         validator.get('commission') or 0)
            
            try:
                commission = float(commission) / 100 if float(commission) > 1 else float(commission)
            except (ValueError, TypeError):
                commission = 0
            
            row = {
                'validator_address': address,
                'validator_name': name,
                'voting_power': voting_powers.get(address, 0),
                'gas_price': gas_prices.get(address, ref_gas_price),
                'stake': stake,
                'commission_rate': commission
            }
            data.append(row)
        
        df = pd.DataFrame(data)
        
        metadata = {
            'epoch': system_state.get('epoch', 'unknown'),
            'reference_gas_price': ref_gas_price,
            'total_validators': len(validators),
            'timestamp': datetime.now().isoformat(),
            'rpc_url': self.rpc_url
        }
        
        return df, metadata
    
    def calculate_weighted_statistics(self, df: pd.DataFrame) -> Dict:
        """
        Calculate vote power weighted gas price statistics
        
        Args:
            df: DataFrame with validator data
            
        Returns:
            Dictionary with statistical measures
        """
        # Remove validators with zero voting power or gas price
        valid_df = df[(df['voting_power'] > 0) & (df['gas_price'] > 0)].copy()
        
        if valid_df.empty:
            return {}
        
        # Calculate weighted average (mean)
        weights = valid_df['voting_power'] / 100  # Convert percentage to fraction
        weighted_mean = np.average(valid_df['gas_price'], weights=weights)
        
        # For weighted median, we need to sort and find the cumulative weight point
        sorted_df = valid_df.sort_values('gas_price')
        cumulative_weights = np.cumsum(sorted_df['voting_power'] / 100)
        
        # Weighted median
        median_idx = np.searchsorted(cumulative_weights, 0.5)
        weighted_median = sorted_df.iloc[median_idx]['gas_price']
        
        # Weighted 25th percentile
        p25_idx = np.searchsorted(cumulative_weights, 0.25)
        weighted_p25 = sorted_df.iloc[p25_idx]['gas_price']
        
        # Weighted 75th percentile
        p75_idx = np.searchsorted(cumulative_weights, 0.75)
        weighted_p75 = sorted_df.iloc[p75_idx]['gas_price']
        
        # Mode (most common gas price, weighted by voting power)
        # Group by gas price and sum voting power
        price_groups = valid_df.groupby('gas_price')['voting_power'].sum()
        weighted_mode = price_groups.idxmax()
        
        # Unweighted statistics for comparison
        unweighted_mean = valid_df['gas_price'].mean()
        unweighted_median = valid_df['gas_price'].median()
        unweighted_p25 = valid_df['gas_price'].quantile(0.25)
        unweighted_p75 = valid_df['gas_price'].quantile(0.75)
        
        return {
            'weighted_mean': weighted_mean,
            'weighted_median': weighted_median,
            'weighted_mode': weighted_mode,
            'weighted_p25': weighted_p25,
            'weighted_p75': weighted_p75,
            'unweighted_mean': unweighted_mean,
            'unweighted_median': unweighted_median,
            'unweighted_p25': unweighted_p25,
            'unweighted_p75': unweighted_p75,
            'total_voting_power': valid_df['voting_power'].sum(),
            'validators_count': len(valid_df)
        }
    
    def create_visualization(self, df: pd.DataFrame, stats: Dict, metadata: Dict):
        """
        Create visualization of the data
        
        Args:
            df: DataFrame with validator data
            stats: Statistical measures
            metadata: Analysis metadata
        """
        fig, ((ax1, ax2), (ax3, ax4)) = plt.subplots(2, 2, figsize=(16, 12))
        fig.suptitle(f'Sui Validator Gas Price Analysis - Epoch {metadata["epoch"]}', fontsize=16)
        
        # Filter valid data
        valid_df = df[(df['voting_power'] > 0) & (df['gas_price'] > 0)].copy()
        
        # 1. Scatter plot: Voting Power vs Gas Price
        scatter = ax1.scatter(valid_df['voting_power'], valid_df['gas_price'], 
                             s=valid_df['voting_power']*10, alpha=0.6, c=valid_df['gas_price'], 
                             cmap='viridis')
        ax1.set_xlabel('Voting Power (%)')
        ax1.set_ylabel('Gas Price (MIST)')
        ax1.set_title('Validator Voting Power vs Gas Price')
        ax1.grid(True, alpha=0.3)
        plt.colorbar(scatter, ax=ax1, label='Gas Price (MIST)')
        
        # Add statistical lines
        ax1.axhline(y=stats['weighted_mean'], color='red', linestyle='--', 
                   label=f'Weighted Mean: {stats["weighted_mean"]:.0f}')
        ax1.axhline(y=stats['weighted_median'], color='orange', linestyle='--', 
                   label=f'Weighted Median: {stats["weighted_median"]:.0f}')
        ax1.legend()
        
        # 2. Histogram of Gas Prices (weighted by voting power)
        weights = valid_df['voting_power'] / 100
        ax2.hist(valid_df['gas_price'], weights=weights, bins=20, alpha=0.7, color='skyblue', edgecolor='black')
        ax2.axvline(stats['weighted_mean'], color='red', linestyle='--', linewidth=2, label='Weighted Mean')
        ax2.axvline(stats['weighted_median'], color='orange', linestyle='--', linewidth=2, label='Weighted Median')
        ax2.axvline(stats['weighted_mode'], color='green', linestyle='--', linewidth=2, label='Weighted Mode')
        ax2.axvline(stats['weighted_p25'], color='purple', linestyle=':', linewidth=2, label='25th Percentile')
        ax2.axvline(stats['weighted_p75'], color='purple', linestyle=':', linewidth=2, label='75th Percentile')
        ax2.set_xlabel('Gas Price (MIST)')
        ax2.set_ylabel('Weighted Frequency')
        ax2.set_title('Vote Power Weighted Gas Price Distribution')
        ax2.legend()
        ax2.grid(True, alpha=0.3)
        
        # 3. Top validators by voting power
        top_validators = valid_df.nlargest(10, 'voting_power')
        bars = ax3.bar(range(len(top_validators)), top_validators['voting_power'], 
                      color=plt.cm.viridis(top_validators['gas_price'] / top_validators['gas_price'].max()))
        ax3.set_xlabel('Validator Rank')
        ax3.set_ylabel('Voting Power (%)')
        ax3.set_title('Top 10 Validators by Voting Power')
        ax3.set_xticks(range(len(top_validators)))
        ax3.set_xticklabels([f"{name[:10]}..." if len(name) > 10 else name 
                            for name in top_validators['validator_name']], rotation=45)
        ax3.grid(True, alpha=0.3)
        
        # 4. Statistics comparison table
        ax4.axis('tight')
        ax4.axis('off')
        
        stats_data = [
            ['Metric', 'Weighted', 'Unweighted'],
            ['Mean', f"{stats['weighted_mean']:.0f}", f"{stats['unweighted_mean']:.0f}"],
            ['Median', f"{stats['weighted_median']:.0f}", f"{stats['unweighted_median']:.0f}"],
            ['25th Percentile', f"{stats['weighted_p25']:.0f}", f"{stats['unweighted_p25']:.0f}"],
            ['75th Percentile', f"{stats['weighted_p75']:.0f}", f"{stats['unweighted_p75']:.0f}"],
            ['Mode', f"{stats['weighted_mode']:.0f}", 'N/A'],
            ['', '', ''],
            ['Reference Gas Price', f"{metadata['reference_gas_price']}", ''],
            ['Total Validators', f"{stats['validators_count']}", ''],
            ['Analysis Time', metadata['timestamp'][:19], '']
        ]
        
        table = ax4.table(cellText=stats_data, cellLoc='center', loc='center')
        table.auto_set_font_size(False)
        table.set_fontsize(10)
        table.scale(1.2, 1.5)
        ax4.set_title('Statistical Summary', pad=20)
        
        plt.tight_layout()
        
        # Save plot
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        filename = f"sui_validator_analysis_{timestamp}.png"
        plt.savefig(filename, dpi=300, bbox_inches='tight')
        print(f"Visualization saved as: {filename}")
        
        plt.show()
    
    def _convert_to_json_serializable(self, obj):
        """
        Convert numpy types to JSON serializable types
        """
        if isinstance(obj, np.integer):
            return int(obj)
        elif isinstance(obj, np.floating):
            return float(obj)
        elif isinstance(obj, np.ndarray):
            return obj.tolist()
        elif isinstance(obj, dict):
            return {key: self._convert_to_json_serializable(value) for key, value in obj.items()}
        elif isinstance(obj, list):
            return [self._convert_to_json_serializable(item) for item in obj]
        else:
            return obj

    def save_data(self, df: pd.DataFrame, stats: Dict, metadata: Dict):
        """
        Save analysis data to CSV and JSON files
        
        Args:
            df: DataFrame with validator data
            stats: Statistical measures
            metadata: Analysis metadata
        """
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        
        # Save CSV
        csv_filename = f"sui_validators_{timestamp}.csv"
        df.to_csv(csv_filename, index=False)
        print(f"Validator data saved as: {csv_filename}")
        
        # Convert all data to JSON serializable format
        json_stats = self._convert_to_json_serializable(stats)
        json_metadata = self._convert_to_json_serializable(metadata)
        
        # Save statistics and metadata
        json_filename = f"sui_analysis_{timestamp}.json"
        output_data = {
            'metadata': json_metadata,
            'statistics': json_stats,
            'summary': {
                'total_validators': int(len(df)),
                'active_validators': int(len(df[df['voting_power'] > 0])),
                'unique_gas_prices': int(df['gas_price'].nunique()),
                'gas_price_range': {
                    'min': float(df['gas_price'].min()),
                    'max': float(df['gas_price'].max())
                }
            }
        }
        
        with open(json_filename, 'w') as f:
            json.dump(output_data, f, indent=2)
        print(f"Analysis summary saved as: {json_filename}")
    
    def run_analysis(self, save_files: bool = True, show_plot: bool = True) -> Tuple[pd.DataFrame, Dict]:
        """
        Run complete analysis
        
        Args:
            save_files: Whether to save output files
            show_plot: Whether to display the plot
            
        Returns:
            DataFrame with validator data and statistics dictionary
        """
        print("Starting Sui validator analysis...")
        
        # Collect data
        df, metadata = self.collect_data()
        
        # Calculate statistics
        stats = self.calculate_weighted_statistics(df)
        
        if not stats:
            raise Exception("Failed to calculate statistics - no valid validator data")
        
        # Print summary
        print("\n" + "="*60)
        print("ANALYSIS SUMMARY")
        print("="*60)
        print(f"Epoch: {metadata['epoch']}")
        print(f"Total Validators: {len(df)}")
        print(f"Reference Gas Price: {metadata['reference_gas_price']} MIST")
        print(f"\nVote Power Weighted Gas Price Statistics:")
        print(f"  Mean: {stats['weighted_mean']:.0f} MIST")
        print(f"  Median: {stats['weighted_median']:.0f} MIST")
        print(f"  Mode: {stats['weighted_mode']:.0f} MIST")
        print(f"  25th Percentile: {stats['weighted_p25']:.0f} MIST")
        print(f"  75th Percentile: {stats['weighted_p75']:.0f} MIST")
        print(f"\nUnweighted Comparison:")
        print(f"  Mean: {stats['unweighted_mean']:.0f} MIST")
        print(f"  Median: {stats['unweighted_median']:.0f} MIST")
        
        # Save files
        if save_files:
            self.save_data(df, stats, metadata)
        
        # Create visualization
        if show_plot:
            self.create_visualization(df, stats, metadata)
        
        return df, stats

def main():
    parser = argparse.ArgumentParser(description='Analyze Sui validator voting power and gas prices')
    parser.add_argument('--rpc-url', default='https://fullnode.mainnet.sui.io:443',
                       help='Sui RPC endpoint URL')
    parser.add_argument('--no-save', action='store_true',
                       help='Do not save output files')
    parser.add_argument('--no-plot', action='store_true',
                       help='Do not display plots')
    
    args = parser.parse_args()
    
    try:
        analyzer = SuiValidatorAnalyzer(args.rpc_url)
        df, stats = analyzer.run_analysis(
            save_files=not args.no_save,
            show_plot=not args.no_plot
        )
        print("\nAnalysis completed successfully!")
        
    except Exception as e:
        print(f"Error: {e}")
        return 1
    
    return 0

if __name__ == "__main__":
    exit(main())
    
