<?php

namespace App\Concerns;

/**
 * Shared organisational fixtures for the scaffolded ledger pages.
 *
 * SCAFFOLD ONLY — delete this trait once the pages read dbo.vw_FinanceLedger.
 * It exists so the different views show the SAME institutions, departments and
 * accounts as each other; a reviewer comparing two pages should not be
 * distracted by them describing different organisations.
 */
trait SampleLedgerFixtures
{
    /**
     * [cluster, institution, institutionId, responsibility, responsibilityId,
     *  department, departmentId]
     *
     * @return array<int,array{0:string,1:string,2:string,3:string,4:string,5:string,6:string}>
     */
    protected function sampleUnits(): array
    {
        return [
            ['SOUTH WEST', 'SAN FERNANDO GENERAL HOSPITAL', 'H01', 'MEDICAL SERVICES', '107', 'PHARMACY', '1157'],
            ['SOUTH WEST', 'SAN FERNANDO GENERAL HOSPITAL', 'H01', 'MEDICAL SERVICES', '107', 'RADIOLOGY', '1162'],
            ['SOUTH WEST', 'SAN FERNANDO GENERAL HOSPITAL', 'H01', 'NURSING SERVICES', '112', 'ACCIDENT AND EMERGENCY', '1204'],
            ['SOUTH WEST', 'POINT FORTIN AREA HOSPITAL', 'H04', 'MEDICAL SERVICES', '107', 'PHARMACY', '1158'],
            ['SOUTH WEST', 'POINT FORTIN AREA HOSPITAL', 'H04', 'SUPPORT SERVICES', '131', 'FACILITIES MAINTENANCE', '1442'],
            ['CENTRAL', 'PRINCES TOWN DISTRICT HEALTH FACILITY', 'H07', 'NURSING SERVICES', '112', 'OUTPATIENT CLINIC', '1219'],
            ['CENTRAL', 'COUVA DISTRICT HEALTH FACILITY', 'H09', 'SUPPORT SERVICES', '131', 'FACILITIES MAINTENANCE', '1447'],
            ['SOUTH EAST', 'SIPARIA DISTRICT HEALTH FACILITY', 'H12', 'ADMINISTRATION', '145', 'CORPORATE SERVICES', '1503'],
            ['SOUTH EAST', 'RIO CLARO DISTRICT HEALTH FACILITY', 'H14', 'NURSING SERVICES', '112', 'OUTPATIENT CLINIC', '1221'],
        ];
    }

    /**
     * [natural account segment, description]
     *
     * @return array<int,array{0:string,1:string}>
     */
    protected function sampleAccounts(): array
    {
        return [
            ['80400', 'MEDICAL SUPPLIES AND DRUGS'],
            ['80410', 'PHARMACEUTICALS'],
            ['80500', 'SURGICAL SUNDRIES'],
            ['81200', 'LABORATORY REAGENTS'],
            ['82100', 'OFFICE SUPPLIES AND STATIONERY'],
            ['83000', 'REPAIRS AND MAINTENANCE - BUILDING'],
            ['83100', 'REPAIRS AND MAINTENANCE - EQUIPMENT'],
            ['84200', 'ELECTRICITY'],
            ['84300', 'WATER AND SEWERAGE'],
            ['85100', 'CONTRACT CLEANING SERVICES'],
            ['86200', 'SECURITY SERVICES'],
            ['87400', 'TRAVELLING AND SUBSISTENCE'],
        ];
    }

    /** Layout: {prefix}-{account}-{institution}-{responsibility}-{department}-00-000 */
    protected function sampleAccountNumber(string $accountSegment, string $institutionId, string $responsibilityId, string $departmentId): string
    {
        return "4-{$accountSegment}-{$institutionId}-{$responsibilityId}-{$departmentId}-00-000";
    }
}
