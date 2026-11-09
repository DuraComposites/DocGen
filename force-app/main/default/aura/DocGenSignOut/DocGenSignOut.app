<aura:application access="GLOBAL" extends="ltng:outApp" implements="ltng:allowGuestAccess" description="Lightning Out App to expose DocGen LWC publicly.">
    <!-- Modified by Dura Composites Ltd. -->
    <!-- Dependency required to inject our Signature LWC -->
    <aura:dependency resource="c:docGenSignaturePad"/>
</aura:application>
